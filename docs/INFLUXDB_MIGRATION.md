# Network Monitor: migrazione a InfluxDB 2 su NUC2

Intervento applicato il **9 novembre 2026**. Il network monitor installato su **NUC2** ora usa InfluxDB OSS **2.7.12** per i nuovi campioni. **NUC1 resta sul backend MariaDB**; il protocollo di traffico fra i due NUC non cambia.

Test automatici e di integrazione ripetuti, più nuovo collaudo fra i due NUC prima della pubblicazione: [VALIDATION_20261109.md](VALIDATION_20261109.md).

## Stato applicato e dati preesistenti

- Installato il pacchetto ufficiale amd64, verificando SHA-256 contro la release upstream.
- Servizio `influxdb` abilitato all'avvio. HTTP limitato a `127.0.0.1:8086`: il DB locale non è esposto alle VLAN di test.
- Organizzazione e bucket: `network-monitor`, senza scadenza automatica dei dati.
- `/opt/network_monitor2/setup.conf`: `DB_BACKEND=influxdb`, URL locale, organizzazione, bucket e token bucket-scoped di lettura/scrittura.
- ACL di sola lettura di `tuser` conservata; nessun privilegio sudo assegnato al runtime.
- Gli script aggiornati sono stati distribuiti in `/opt/network_monitor2` su NUC2.
- MariaDB rimane attivo per **LibreNMS**, che continua a usare il proprio DB applicativo e RRD. Non è stato migrato LibreNMS.
- Lo storico del network monitor in MariaDB è conservato e **non è stato importato** nel nuovo bucket. Export e nuova dashboard InfluxDB mostrano i dati del nuovo backend; per lo storico usare la configurazione MariaDB o le dashboard precedenti.
- Nessuna modifica all'istanza InfluxDB `10.10.27.41:8086`, ai gateway INDRA o alla configurazione di NUC1.

Backup precedente al cambio di backend: `/var/backups/network_monitor2/20261109_171348/runtime`, accessibile solo all'amministratore. Contiene configurazione, script e virtualenv precedenti. Non pubblicare questi file: includono credenziali reali.

## Architettura

Gli stessi parser continuano a raccogliere iperf3, ping e interruzioni. La selezione `DB_BACKEND=mariadb|influxdb` conserva la compatibilità con le installazioni esistenti: senza impostazione esplicita il default resta MariaDB.

`network_monitor/storage.sh` seleziona il backend e il Python della virtualenv installata. `influx_store.py` usa le API HTTP InfluxDB 2 `/api/v2/write` e `/api/v2/query` (Flux), con la sola standard library Python. I token non sono passati negli argomenti dei processi.

Il launcher assegna un `NM_RUN_ID` condiviso dai collector della singola invocazione e verifica la connessione di lettura a InfluxDB prima di generare traffico. Gli errori di scrittura iperf fanno fallire il collector; gli errori dei monitor in background vengono controllati alla conclusione del client. Le scritture ritentano fino a tre volte solo per errori transitori, riutilizzando lo stesso punto. **Non esiste una coda persistente per le scritture offline.**

### Contratto dei dati

| Measurement predefinita | Campi |
|---|---|
| `iperf_results` | bitrate (Mbit/s), jitter (ms), lost_percentage (%), packet_size, window_size, executed_command |
| `ping_results` | latency (ms) |
| `interruptions` | interruption_time (secondi) |

Tag comuni: `host`, `run_id`. Iperf aggiunge `protocol` e, quando presenti nei metadata del parser, `role`, `local_ip`, `remote_ip`, `direction`. Ping/interruzioni aggiungono endpoint sorgente e destinazione. I timestamp locali dei collector vengono convertiti in UTC, con precisione nanosecondi nel protocollo di scrittura; la precisione effettiva dei campioni originari resta quella dei collector.

I nomi delle measurement seguono `IPERF_TABLE`, `PING_TABLE`, `INTERRUPTIONS_TABLE`. L'export filtra di default per hostname locale; è disponibile `INFLUX_HOST_FILTER` per selezionare un diverso nodo.

## Excel e peer ancora su MariaDB

La CLI rimane invariata:

```bash
network_monitor2 --export-excel risultati.xlsx
network_monitor2 --export-excel risultati.xlsx \
  --start "2026-11-09 17:00:00" --end "2026-11-09 17:30:00"
```

Sono mantenuti fogli e colonne esistenti, filtri temporali inclusivi e suffisso dell'intervallo nel nome. InfluxDB non ha l'ID auto-incrementante MariaDB: gli ID delle righe esportate sono numeri di sequenza dell'export, non identificatori persistenti.

Se configurato, `REMOTE_DB_HOST` permette ancora di affiancare campioni del peer MariaDB; la connessione è di lettura. In alternativa si possono definire `REMOTE_INFLUX_URL`, `REMOTE_INFLUX_ORG`, `REMOTE_INFLUX_BUCKET`, `REMOTE_INFLUX_TOKEN`, `REMOTE_INFLUX_HOST` per un peer InfluxDB. La semantica precedente di affiancamento per run/intervallo resta invariata; non è stata introdotta una sincronizzazione fra i due nodi.

## Grafana e accesso amministrativo

Datasource locale aggiuntivo `NetworkMonitorInfluxDB`, con token **read-only** limitato al bucket. La dashboard **Network Monitor — InfluxDB** è nella cartella **Network Monitor**:

```text
http://10.10.27.11:3000/d/network-monitor-influxdb
```

Contiene throughput, jitter, perdita, latenza, interruzioni e metadata, con filtro host. Le vecchie dashboard MariaDB restano disponibili per lo storico e NUC1. I file di provisioning sono sotto `/etc/grafana/provisioning/`; il JSON è sotto `/var/lib/grafana/dashboards/network-monitor-influxdb/`.

Il provisioning della dashboard è stato verificato anche nello storage unificato di Grafana 12.4.2: la vecchia tabella SQL `dashboard` non contiene necessariamente i nuovi dashboard. Tutte le query dei sei pannelli sono state eseguite direttamente con il token read-only; non è stato eseguito un collaudo visivo nel browser.

Le credenziali iniziali di amministrazione InfluxDB sono in `/root/network-monitor-influxdb-admin.json`, modo 600. Non copiarle nel repository o in messaggi. Per la UI di InfluxDB da un computer esterno:

```bash
ssh -L 8086:127.0.0.1:8086 comsa@10.10.27.11
# Aprire http://localhost:8086 sul computer da cui parte SSH.
```

Il token runtime è nella configurazione protetta; il token Grafana è nel file di provisioning leggibile dal gruppo grafana. Non usare il token amministrativo nel runtime.

## Installazione riproducibile

Per il backend InfluxDB su un NUC amd64 Debian/Ubuntu:

```bash
sudo bash setup_v2.sh --influxdb
```

Il percorso senza flag resta il setup MariaDB. Gli helper sono `scripts/install_influxdb2.sh` e `scripts/provision_influxdb2.py`. La versione è fissata a 2.7.12 per allineamento con l'istanza di laboratorio individuata sulla management. L'installer è per un server locale; non sovrascrivere configurazioni di un'istanza condivisa già esistente.

Il provisioning rifiuta un server già inizializzato se mancano le credenziali bootstrap root-only note. Su una ripetizione conserva il token runtime esistente, crea un nuovo backup e un nuovo token read-only Grafana. Non cancella lo storico né revoca token di altre applicazioni. Rivedere/ruotare i vecchi token read-only qualora si ripeta il provisioning più volte.

## Verifiche eseguite

- Sintassi degli script shell modificati e compilazione Python.
- Test esistenti: opzioni network monitor, matrice Cedex e naming export.
- Sei test del nuovo storage: unità/metadata, escaping, timestamp/filtro inclusivo, CSV multi-tabella, retry HTTP, contratto Excel anche con measurement vuote.
- Test live **in un bucket temporaneo distinto dalla produzione**: scrittura/lettura di iperf, ping e interruzioni, escaping dei metadata, export di tutti i fogli e rifiuto delle scritture con token read-only. Bucket e token di verifica eliminati dopo la prova.
- Client NUC2 eseguito come `tuser` contro NUC1 management: UDP 5 s a 1 Mbit/s, UDP reverse 5 s a 1 Mbit/s, TCP 3 s. Tutti con exit 0; campioni InfluxDB: 10 UDP client e 3 TCP client, più ping.
- Server NUC2 eseguito come `tuser`, client iperf su NUC1: UDP/TCP 3 s a circa 1 Mbit/s, 3 campioni server per protocollo. Protocollo rilevato correttamente.
- Export reale come `tuser`: completato, workbook generato.
- Servizi InfluxDB, MariaDB e Grafana attivi dopo il provisioning; dashboard e datasource caricati. I processi di test sono temporanei.
- Ultima distribuzione verificata confrontando tutti i file runtime `.sh`/`.py` con il workspace; ulteriore smoke test loopback come tuser riuscito (UDP 2 s, 209 datagrammi, zero persi). Preflight con token volutamente invalido rifiutato con HTTP 401. I token reali non sono stati stampati.
- Query SQL locale sul periodo delle prove: zero nuovi campioni iperf MariaDB su NUC2, a conferma del cambio di backend. Export limitato all'intervallo delle prove: 19 righe iperf, 15 ping, 19 metadata e nessuna interruzione reale.

Log/workbook locali sotto `results/influxdb_migration_20261109/`, esclusi da Git. I risultati sopra sono il riepilogo trasferibile. Nessuna simulazione di guasto è stata applicata alla rete reale: gli eventi di interruzione sintetici sono stati verificati solo nel bucket temporaneo.

Comandi per ripetere i test di codice:

```bash
python3 tests/test_influx_store.py
python3 tests/test_export_filename.py
bash tests/test_base_measurement_matrix.sh
bash tests/test_network_monitor_options.sh
# Solo sul NUC con le credenziali bootstrap note, bucket temporaneo:
sudo python3 tests/integration_influxdb2.py
```

## Ripristino e attività separate

Per tornare alle nuove scritture MariaDB su NUC2, un amministratore può impostare `DB_BACKEND=mariadb` nel setup.conf conservando le precedenti credenziali DB. L'export seguirà quel backend; i dati già scritti in InfluxDB non vengono cancellati. Per ripristinare anche il codice, usare il backup runtime dopo aver fermato solo gli eventuali processi network_monitor2 attivi; preservare le ACL. Non rimuovere MariaDB o i database di LibreNMS.

Migrare lo storico SQL, portare anche NUC1 a InfluxDB, centralizzare i due nodi e risolvere i gateway INDRA sono attività **distinte, non eseguite in questo intervento**.

Riferimenti ufficiali: [installazione InfluxDB 2](https://docs.influxdata.com/influxdb/v2/install/), [release 2.7.12 e checksum](https://github.com/influxdata/influxdb/releases/tag/v2.7.12), [API](https://docs.influxdata.com/influxdb/v2/reference/api/).
