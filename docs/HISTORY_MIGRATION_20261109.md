# Migrazione dello storico MariaDB → InfluxDB, NUC2

Completata il **9 novembre 2026 alle 18:23:48 CET**. Sorgente: database locale **comsa_v2** del network monitor su NUC2. Destinazione: bucket **network-monitor** dell'InfluxDB 2.7.12 locale. Sono stati importati **5.302.235 record**. Nessun dato MariaDB è stato eliminato o modificato; LibreNMS e NUC1 non sono stati migrati.

**Controllo successivo indipendente:** alle 18:31 CET tutti i record sono stati riletti dai database attuali e confrontati per ID, senza differenze, mancanti o duplicati. Vedere [DATABASE_COMPARISON_20261109.md](DATABASE_COMPARISON_20261109.md).

## Record trasferiti e verificati

| Tabella sorgente / measurement destinazione | Record | Verifica completa |
|---|---:|---|
| iperf_results | 30.952 | PASS |
| ping_results | 5.271.269 | PASS |
| interruptions | 1 | PASS |
| nm_iperf_samples | 9 | PASS |
| nm_ping_samples | 4 | PASS |
| nm_interrupt_events | 0 | PASS, tabella vuota nel manifest |
| **Totale** | **5.302.235** | **PASS** |

Sono incluse le tre piccole tabelle nm_* di test presenti nel DB del tool: mantengono measurement separate, senza mescolarle alle serie operative. Una tabella vuota non genera punti InfluxDB; la sua struttura è nel backup SQL e nel manifest.

I 60 punti live preesistenti in InfluxDB (31 iperf, 29 ping) sono stati confrontati prima/dopo e sono invariati. I dati importati più vecchi non sovrascrivono i punti live.

## Backup e tracciabilità

Directory protetta, accessibile all'amministratore:

```text
/var/backups/network_monitor_history/20261109/
  source.sql.gz
  <tabella>.jsonl.gz
  manifest.json
  preexisting_influx.json
  progress.log
```

È stato creato un dump SQL single-transaction delle sole sei tabelle del network monitor, più snapshot JSON compressi e ordinati per timestamp/id. Il dump SQL ha SHA-256:

```text
d3dc939a2d928f241b732258122784483e03829eeb259b2a79037c630c64fd65
```

Il manifest contiene schema delle colonne, massimo ID, conteggi, checksum degli snapshot, distribuzione temporale UTC e fingerprint del contenuto per ogni tabella. Backup e snapshot completi occupano circa 105 MB compressi. Non includere dump o snapshot delle righe nel repository.

Copie locali di manifest, log e workbook di verifica: `results/history_migration_20261109/`, escluse da Git. I backup originali e gli snapshot JSON restano nella directory protetta.

## Mapping senza perdita delle righe originali

- Ogni record originale produce un punto. Le metriche mantengono le unità esistenti e i valori restituiti da MariaDB.
- `host=nuc2`, `migration_source=mariadb`, `source_db=comsa_v2`, `source_table=<tabella>` identificano la provenienza.
- `run_id=mariadb-comsa_v2-<tabella>` è stabile. Non rappresenta il run originale: il DB storico non aveva un identificatore di run strutturato per ogni riga.
- `legacy_id` conserva l'ID originale come stringa, senza perdita di precisione.
- `legacy_row` conserva la riga originale come JSON canonico: comprende anche timestamp locale originale, NULL, stringhe vuote, metadata e colonne non presenti nelle altre tabelle.
- I timestamp DATETIME sono interpretati in **Europe/Madrid** e convertiti in UTC. Nessuna riga ricade nell'ora ambigua del cambio DST. Il programma documenta comunque la politica fold=0 per un eventuale futuro dataset ambiguo; il timestamp locale grezzo resta archiviato.
- Per record con stesso timestamp, `legacy_slot` assegna un ordinale stabile, ordinando per ID. Mantiene il timestamp esatto e distingue i punti senza aggiungere una serie per ogni ID.
- La stessa sorgente/snapshot genera le stesse chiavi InfluxDB. Riscrivere un blocco già importato aggiorna gli stessi punti, senza duplicarli. Verificato anche dal vivo ripetendo i primi 100 record disponibili di ogni tabella e ricontrollando i conteggi.

I campi SQL di protocollo e metadata sono conservati, senza correggere retroattivamente eventuali errori delle vecchie versioni del tool.

## Riconciliazione completa

La verifica non si è limitata ai conteggi o a un campione:

1. Conteggi degli snapshot uguali a quelli delle tabelle sorgenti.
2. Scritture in blocchi da 5.000 punti, con retry idempotenti del client HTTP.
3. Rilettura di **tutti** i punti importati tramite query Flux a intervalli temporali e CSV streaming.
4. Confronto di ID, timestamp, valori numerici, stringhe e tag di protocollo con la riga originale archiviata. Tolleranza numerica di confronto 1e-12.
5. Conteggio per giorno UTC e fingerprint completo del multinsieme delle righe (somma modulo 2^256 e XOR dei rispettivi SHA-256), identico fra snapshot sorgente e destinazione. Questi fingerprint accompagnano i controlli dei valori, non li sostituiscono.
6. Conteggio e massimo ID delle sorgenti ricontrollati dopo la verifica; nessuna variazione rilevata.
7. Confronto completo dei punti live preesistenti e verifica di idempotenza.

L'importatore usa solo letture su MariaDB. Gli snapshot sono la base immutabile della verifica; non serve arrestare InfluxDB o eliminare dati per riprendere un trasferimento interrotto.

## Programma riutilizzabile e test

```bash
# Snapshot protetto; nessuna scrittura InfluxDB senza --apply:
sudo python3 scripts/migrate_mariadb_history.py \
  --directory /var/backups/network_monitor_history/<nuova-sessione>

# Importazione/ripresa della stessa sessione:
sudo python3 scripts/migrate_mariadb_history.py \
  --directory /var/backups/network_monitor_history/<sessione> --apply
```

Configurazione predefinita: `/opt/network_monitor2/setup.conf`, con credenziali MariaDB precedenti e nuove credenziali InfluxDB. La password SQL è trasmessa nell'ambiente del processo, non negli argomenti o nei log. Il programma rifiuta i DB di sistema e librenms e seleziona solo le tabelle del tool configurate e le tre nm_* note.

Il manifest è un checkpoint: le tabelle già verificate vengono saltate; una tabella con scritture completamente confermate può riprendere dalla verifica. Una migrazione parziale può riscrivere idempotentemente una tabella. Non riutilizzare un manifest per una sorgente differente, né interpretare il flag verified come nuova verifica dopo modifiche successive al bucket.

Test eseguiti dopo l'aggiornamento:

- 6 test in `tests/test_history_migration.py`: identità/stabilità dei punti, isolamento live, fusi/DST, archiviazione dei NULL/stringhe, fingerprint e verifica dei valori/timestamp.
- 7 test storage InfluxDB, incluso rifiuto preventivo degli export troppo grandi.
- Test naming Excel e integrazione live storage/export/read-only in bucket temporaneo: PASS.
- Export storico come tuser dal 14 settembre 2026, 13:03–13:06: PASS, 160 righe iperf, 112 ping, un'interruzione e 160 metadata. Timestamp dell'interruzione esportata: `2026-09-14 13:04:03.077000`, uguale al timestamp locale originale.
- Servizi InfluxDB, MariaDB e Grafana attivi; moduli runtime modificati distribuiti su NUC2.

## Export e dashboard dopo il trasferimento

La dashboard InfluxDB può ora visualizzare anche le misure storiche operative: selezionare la data corretta, anziché l'ultima ora. Le measurement nm_* restano separate e richiedono una query dedicata. Le vecchie dashboard MariaDB restano utilizzabili.

Con oltre cinque milioni di ping un workbook singolo non è una rappresentazione pratica e supera anche il limite di righe di un foglio Excel. L'export InfluxDB effettua ora un conteggio prima di caricare le righe e applica un massimo predefinito di **200.000 righe per measurement**; l'export senza intervallo è stato verificato e termina con un messaggio esplicito, senza esaurire la memoria. Usare finestre temporali limitate:

```bash
network_monitor2 --export-excel storico.xlsx \
  --start "2026-09-14 13:03:00" --end "2026-09-14 13:06:00"
```

`INFLUX_EXPORT_MAX_ROWS` modifica il limite nella configurazione, ma aumentarlo richiede considerare memoria e limiti Excel. Gli ID mostrati nel workbook restano sequenze dell'export; per l'ID SQL originale interrogare il campo legacy_id.

## Ambito e stato Git

Sono migrati i dati del **network monitor locale NUC2**, non tutti i database del server MariaDB, non RRD/LibreNMS e non lo storico di NUC1. Le sorgenti SQL restano una copia aggiuntiva disponibile; nessuna cancellazione è necessaria per usare lo storico importato.

Questa fase aggiunge script, test, aggiornamenti export e documenti rispetto al commit locale `5c0ef21`. Non è stata pubblicata su GitHub: il blocco di autenticazione del push precedente resta documentato in [VALIDATION_20261109.md](VALIDATION_20261109.md).
