# Validazione prima del commit — 9 novembre 2026

Questa verifica è successiva alla migrazione del network monitor su NUC2. Stato operativo e rollback: [INFLUXDB_MIGRATION.md](INFLUXDB_MIGRATION.md). Contesto generale: [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md).

## Test automatici ripetuti

| Verifica | Esito |
|---|---|
| `bash -n` su ogni script in network_monitor/, scripts/ e setup_v2.sh | PASS |
| `python3 -m py_compile` sui moduli runtime, provisioning e nuovi test | PASS |
| `python3 tests/test_influx_store.py` | PASS, 6 test |
| `python3 tests/test_export_filename.py` | PASS |
| `bash tests/test_base_measurement_matrix.sh` | PASS |
| `bash tests/test_network_monitor_options.sh` | PASS, incluso UDP reverse |
| `sudo python3 tests/integration_influxdb2.py` | PASS |

Il test live verifica i tre tipi di campioni (iperf, ping e interruzioni), lettura Flux, metadata con caratteri da escapare, workbook completo e rifiuto delle scritture con token read-only. Usa un bucket temporaneo separato: bucket e token di verifica sono stati rimossi dopo il test, senza introdurre falsi eventi nella produzione.

## Prova reale fra i NUC, ripetuta prima del commit

NUC1 server su `10.10.27.10:5051`, processo temporaneo dell'utente comsa. NUC2 client **come tuser**, sorgente `10.10.27.11`, backend InfluxDB locale. Ogni caso ha un run_id distinto per verificare i campioni realmente registrati.

Intervallo locale: **17:45:11–17:45:22 CET**, 9 novembre 2026.

| Caso | Durata/parametri | Exit | Campioni InfluxDB verificati |
|---|---|---|---|
| UDP forward | 3 s, 1 Mbit/s, datagrammi 1200 byte | 0 | 3, protocollo udp |
| UDP reverse | 3 s, 1 Mbit/s, datagrammi 1200 byte | 0 | 3, protocollo udp |
| TCP | 2 s | 0 | 2, protocollo tcp |

Export Excel come tuser limitato allo stesso intervallo: completato e riletto, con 8 righe iperf, 11 ping, 8 metadata e zero eventi di interruzione. La verifica del backend legge i punti dal bucket e li correla al run_id; non si limita alla riuscita del comando iperf.

Artefatti locali esclusi da Git: `results/release_validation_20261109/{summary.json,udp.log,reverse.log,tcp.log,nuc1_server.log}`. Workbook sotto `/tmp/release_influx_20261109_174511_to_20261109_174522.xlsx` e copia nella cartella dei risultati. Il presente riepilogo è versionato per permettere il passaggio di consegne.

## Stato e limiti

- Servizi `influxdb`, `grafana-server`, `mariadb` attivi; preflight InfluxDB come tuser con exit 0.
- I file runtime installati su NUC2 sono stati confrontati con il workspace.
- I test di codice verificano anche la compatibilità del percorso MariaDB; non costituiscono una reinstallazione completa da zero su una macchina pulita.
- Non è stato ripetuto un collaudo visivo dei pannelli nel browser; le query e il provisioning erano stati verificati durante la migrazione.
- Il percorso INDRA non è incluso in questa prova; il problema dei gateway resta aperto.
- NUC1 rimane su MariaDB; nessun aggiornamento del suo runtime è stato effettuato. Lo storico SQL e LibreNMS restano conservati.
- I listener temporanei e la shell amministrativa vengono chiusi dopo la validazione. Nessun servizio iperf persistente è richiesto dal nuovo backend.

## Contenuto della pubblicazione

Il commit comprende backend InfluxDB 2, aggiornamento collector/export, installer e provisioning, dashboard dedicata, test e documentazione di contesto. Include anche la correzione UDP reverse e il relativo test che erano già presenti nel workspace all'inizio dell'attività, ora verificati con la suite.

Restano esclusi configurazioni reali, token, credenziali, backup di sistema e log/workbook operativi. La versione effettiva del commit e lo stato di sincronizzazione remota si verificano con `git log -1` e `git status -sb`.

## Stato della pubblicazione

Commit creato sul branch locale `main`. Push non completato in questa sessione: HTTPS richiede credenziali non disponibili nel terminale; SSH rifiuta la chiave presente (`Permission denied (publickey)`). La connessione GitHub dell'app legge il repository ma la creazione dell'albero Git è rifiutata con HTTP 403 `Resource not accessible by integration`. Nessun aggiornamento del branch remoto è stato effettuato.

Dopo aver configurato un'autenticazione con permessi di scrittura sul repository, riprendere da `git status -sb`, `git fetch origin` e confronto con `origin/main`, quindi `git push origin main` se la pubblicazione è ancora fast-forward. Non usare force push per superare divergenze.

## Attività successiva: importazione dello storico

Dopo questo commit l'utente ha richiesto anche la migrazione dei dati. Sono stati importati e riconciliati 5.302.235 record di NUC2; vedere [HISTORY_MIGRATION_20261109.md](HISTORY_MIGRATION_20261109.md). La nuova fase ha aggiunto 6 test della migrazione e un settimo test storage per il limite export; integrazione live ed export storico sono riusciti. Queste modifiche successive non sono ancora nel commit 5c0ef21 né pubblicate.
