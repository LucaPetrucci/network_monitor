# Inventario management — 9 novembre 2026

Verifica da NUC2 sulla rete 10.10.27.0/24, senza modifiche ai dispositivi. Obiettivo: individuare InfluxDB, LibreNMS e monitor delle antenne prima di progettare la migrazione del network monitor.

**Aggiornamento successivo alla ricognizione:** è stata installata una nuova istanza InfluxDB 2.7.12 su NUC2, limitata a `127.0.0.1:8086`, e migrato il network monitor locale. Non è esposta sulla management e non modifica le conclusioni su LibreNMS. Vedere [migrazione InfluxDB](INFLUXDB_MIGRATION.md).

## Risultati confermati

| Indirizzo | Servizio identificato | Evidenza |
|---|---|---|
| 10.10.27.10, NUC1 | Grafana su 3000; nessuna installazione InfluxDB rilevata nei controlli effettuati | SSH come comsa: nessun binario influx/influxd/influxdb3 nel PATH, nessun pacchetto o unit file corrispondente, nessun listener 8086/8181/8088; Docker/Podman non trovati nel PATH |
| 10.10.27.11, NUC2 | LibreNMS su HTTP 80; Grafana su 3000 | GET / reindirizza a /login, titolo LibreNMS. Nginx serve /opt/librenms/html; /etc/nginx/sites-enabled/librenms punta al vhost locale |
| 10.10.27.41:8086 | **InfluxDB v2.7.12**, commit ec9dcde5d6 | GET /ping: 204, X-Influxdb-Version v2.7.12. GET /health: 200, status pass, ready for queries and writes |
| 10.10.27.70–74, HTTP 80 | Blu Wireless Device Health Monitor | Titolo Device Health Monitor, logo Blu Wireless DHM, percorsi /dhm/device e /dhm/health |
| 10.10.27.40 e .41, HTTPS 8080 | Applicazione Hypercorn | HTTPS risponde 200, server hypercorn-h11, corpo Hello world; funzione effettiva non identificata |
| 10.10.27.40, HTTP 80 | Apache Ubuntu | Pagina predefinita Apache2 Ubuntu |
| 10.10.27.20 e .21 | Apache Win64 su 8080; servizio HTTP su 8000 | Directory index su 8080, server Apache/2.4.62 (Win64); GET / su 8000 restituisce 404. Applicazione non identificata |

Altri indirizzi con SSH rilevato: .1 e .50, oltre ai nodi già elencati. Nessun accesso autenticato effettuato sui dispositivi diversi da NUC1. Non sono state riutilizzate su altri apparati le credenziali dei NUC.

## Autenticazione e limiti

- La query anonima a InfluxDB `GET /query?q=SHOW%20DATABASES` restituisce 401 Unauthorized. Nessun elenco database/bucket, organizzazione, token o permesso di scrittura è stato verificato. Non sono stati inseriti dati.
- Il controllo successivo della configurazione effettiva LibreNMS, eseguito come utente librenms tramite `lnms config:get`, conferma `influxdb.enable=false`, `influxdbv2.enable=false`, `rrd.enable=true`. Gli host Influx configurati sono i default `127.0.0.1:8086`, con db/bucket/organizzazione librenms: non indicano un'integrazione abilitata. LibreNMS su NUC2 **non usa attualmente InfluxDB** come datastore delle metriche.
- Connessione applicativa verificata tramite bootstrap Laravel e query di sola lettura `SELECT VERSION()`: driver mysql, server `10.11.14-MariaDB-0+deb12u2`. Presenti file .rrd sotto /opt/librenms/rrd, con timestamp recenti al momento del controllo. Dunque DB applicativo MariaDB e datastore metriche RRD; nessuna impostazione modificata.
- Le pagine pubbliche dei DHM non identificano il backend. Non è stato dimostrato che usino l'istanza .41 né che il database sia locale ai dispositivi. Un InfluxDB su loopback o porta diversa non sarebbe rilevato da queste richieste.
- Gli esiti negativi su NUC1 riguardano binari nel PATH, pacchetti Debian, unit file, directory comuni e listener visibili, non una ricerca forense di ogni file o namespace.
- Inventario riferito solo alla VLAN management raggiungibile da NUC2, non all'intera infrastruttura.

## Metodo e artefatti

Discovery TCP/ICMP con `nmap -sn -n 10.10.27.0/24`; controllo mirato TCP connect senza script intrusivi sulle porte 22,80,443,3000,8000,8080,8086,8088,8181,8443, con retry e rate limit. La scansione mirata usa -Pn: la dicitura finale di nmap "256 hosts up" **non è un conteggio di dispositivi vivi**. I servizi aperti sono la prova utilizzata; la discovery iniziale aveva trovato 12 indirizzi e il controllo porte ha individuato anche .50.

Artefatti locali, esclusi da Git: `results/management_inventory_20261109/discovery.txt`, `services.txt`, `services.xml`. Identificazione applicativa tramite GET di pagine, asset JavaScript pubblici, /ping e /health; per .40/.41:8080 è stato necessario HTTPS. Nessuna lettura di file esposti non necessari all'identificazione, nessuna modifica a configurazioni o rete.

## Impatto sulla migrazione del network monitor

Esiste già un server **InfluxDB 2.7.12** sulla management. Non assumere quindi InfluxDB 3 come destinazione della migrazione. Prima di riutilizzarlo occorre chiarire:

1. chi amministra .41 e quali servizi dipendono dall'istanza;
2. organizzazione e bucket dedicati al network monitor, retention e risorse disponibili;
3. credenziali con permessi appropriati per scrittura dei campioni e lettura/export/dashboard;
4. eventuale collegamento con monitor antenne e LibreNMS, senza interferire con dati esistenti;
5. scelta esplicita fra database centrale su .41 e istanze locali sui NUC.

La presenza e la salute dell'istanza non costituiscono autorizzazione o verifica di idoneità a riutilizzare bucket esistenti.
