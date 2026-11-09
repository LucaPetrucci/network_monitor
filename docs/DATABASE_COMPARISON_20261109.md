# Confronto indipendente MariaDB / InfluxDB — 9 novembre 2026

**Esito: PASS. Tutti i 5.302.235 record storici del network monitor NUC2 coincidono.** Verifica eseguita dalle **18:29:46 alle 18:31:25 CET** del 9 novembre 2026.

| Tabella / measurement | MariaDB | InfluxDB storico | Mancanti | Aggiuntivi/duplicati | Diversi |
|---|---:|---:|---:|---:|---:|
| iperf_results | 30.952 | 30.952 | 0 | 0 | 0 |
| ping_results | 5.271.269 | 5.271.269 | 0 | 0 | 0 |
| interruptions | 1 | 1 | 0 | 0 | 0 |
| nm_iperf_samples | 9 | 9 | 0 | 0 | 0 |
| nm_ping_samples | 4 | 4 | 0 | 0 | 0 |
| nm_interrupt_events | 0 | 0 | 0 | 0 | 0 |
| **Totale** | **5.302.235** | **5.302.235** | **0** | **0** | **0** |

## Cosa è stato confrontato

Sorgente **attuale**: database MariaDB `comsa_v2` su NUC2. Destinazione: bucket InfluxDB `network-monitor`, host nuc2, punti marcati `migration_source=mariadb` e con database/tabella sorgente corrispondenti.

Non sono stati riutilizzati i flag verified della migrazione per dichiarare l'uguaglianza. Il nuovo programma [verify_history_databases.py](../scripts/verify_history_databases.py):

1. Rilegge tutte le righe e le colonne attuali di ogni tabella MariaDB, creando un indice temporaneo su disco per ID.
2. Rilegge tutti i punti storici InfluxDB per giorno/ora, in streaming per limitare la memoria.
3. Confronta la rappresentazione canonica di ogni riga SQL con `legacy_row`, verificando esattamente contenuto originale, ID, NULL, stringhe vuote e metadata.
4. Verifica anche che timestamp UTC, campi numerici, campi testuali e protocollo proiettati nel punto InfluxDB corrispondano alla riga originale. I valori numerici sono confrontati con tolleranza relativa/assoluta 1e-12 per la rappresentazione floating point; l'archivio della riga originale è confrontato esattamente.
5. Rimuove ogni ID corrispondente dal solo indice temporaneo: un secondo punto con lo stesso ID viene segnalato come duplicato, un ID non trovato come aggiuntivo, un ID rimasto come mancante.
6. Controlla conteggi giornalieri, conteggio totale dei punti storici anche fuori dalle giornate attese e stabilità del conteggio/massimo ID della sorgente durante il controllo.

L'indice di verifica non è un database operativo e viene cancellato al termine di ciascuna tabella. Il confronto non modifica MariaDB né i punti InfluxDB di produzione.

I punti **nativi**, raccolti direttamente in InfluxDB dopo il cambio di backend, non esistono nel vecchio MariaDB e sono intenzionalmente esclusi da questo confronto. L'uguaglianza riguarda l'intero storico trasferito, non il numero totale di punti del bucket includendo le nuove misure. Non riguarda LibreNMS o i database di NUC1.

## Test ripetuti nella stessa sessione

- `tests/test_influx_store.py`: **7 test, PASS**.
- `tests/test_history_migration.py`: **6 test, PASS**.
- `tests/test_export_filename.py`: **PASS**.
- `tests/test_base_measurement_matrix.sh`: **PASS**.
- `tests/test_network_monitor_options.sh`: **PASS**, incluso UDP reverse.
- `tests/integration_influxdb2.py`: **PASS**, scrittura/lettura/export e token read-only in bucket temporaneo, poi eliminato.
- Sintassi shell, compilazione Python e `git diff --check`: **PASS**.
- Servizi InfluxDB, MariaDB e Grafana: **active** dopo il controllo.

## Evidenze e ripetizione

Rapporto JSON originale: `/var/backups/network_monitor_history/recheck_20261109/report.json`. Log completo: `/var/backups/network_monitor_history/recheck_20261109.log`. Copie locali sotto `results/database_comparison_20261109/`, escluse da Git. Il presente documento è il riepilogo trasferibile.

Per ripetere il confronto usare una **nuova** directory:

```bash
sudo python3 scripts/verify_history_databases.py \
  --manifest /var/backups/network_monitor_history/20261109/manifest.json \
  --directory /var/backups/network_monitor_history/recheck_<nuova-data-ora>
```

Il manifest identifica le tabelle migrate e gli intervalli originali; i valori confrontati sono riletti dai due database. Le credenziali provengono dalla configurazione protetta, non dagli argomenti o dal rapporto.
