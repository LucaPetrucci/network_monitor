# Guida rapida a network_monitor2

Questa guida spiega come avviare `network_monitor2` su due NUC, eseguire test TCP e UDP su una VLAN specifica e consultare i risultati. È una versione operativa e semplificata del README del progetto.

## 1. Che cosa fa il tool

`network_monitor2` combina tre tipi di misura:

- ping, per latenza e raggiungibilità;
- iperf3, per throughput TCP/UDP, jitter e packet loss;
- monitoraggio delle interruzioni durante il test.

Ogni NUC salva i propri risultati nel database MariaDB locale. Il tool non scrive direttamente nel database dell'altro NUC.

## 2. Prerequisiti

Il tool deve essere installato su entrambi i NUC. Verificare con:

```bash
command -v network_monitor2
network_monitor2 --help
command -v iperf3
```

Se non è ancora installato:

```bash
cd /home/comsa/network_monitor_v2
sudo bash ./setup_v2.sh
```

La configurazione del database utilizzata dal runtime si trova in:

```text
/opt/network_monitor2/setup.conf
```

## 3. Regola fondamentale: server e client

Per ogni test servono due terminali:

1. sul NUC che riceve il traffico si avvia `network_monitor2 --server`;
2. sull'altro NUC si avvia il client indicando l'indirizzo del server.

Il server deve essere avviato prima del client. La porta e gli indirizzi di binding devono corrispondere.

Poiché i NUC hanno più VLAN, utilizzare sempre:

- `--bind-ip` sul server;
- `--source-ip` sul client.

Questo evita che Linux scelga un'interfaccia diversa da quella da misurare.

## 4. Verifiche prima del test

Controllare indirizzi e interfacce:

```bash
ip -br addr
ip route
```

Verificare la raggiungibilità usando l'indirizzo sorgente corretto:

```bash
ping -I <IP_LOCALE_TEST> -c 5 <IP_REMOTO_TEST>
```

Esempio TN0 da NUC2:

```bash
ping -I 10.10.28.11 -c 5 10.10.28.10
```

Se il ping restituisce 100% packet loss, non avviare il test di throughput: controllare prima routing, VLAN, ARP e stato del collegamento.

## 5. Primo test TCP: NUC2 verso NUC1

### Terminale 1 — NUC1 server

Collegarsi a NUC1 attraverso la rete di management:

```bash
ssh 10.10.27.10
```

Avviare il server vincolato all'indirizzo TN0 di NUC1:

```bash
network_monitor2 --server \
  --bind-ip 10.10.28.10 \
  --interface enp114s0.28 \
  --port 5050
```

Lasciare questo terminale aperto.

### Terminale 2 — NUC2 client

Da NUC2 eseguire un test TCP di 30 secondi:

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --interface enp114s0.28 \
  --port 5050 \
  --duration 30 \
  --tcp
```

Durante il test vengono mostrati a terminale gli intervalli iperf3 e il riepilogo finale. Ping, throughput e interruzioni vengono anche salvati nel database locale.

Per fermare il server al termine dei test premere `Ctrl+C` nel terminale di NUC1.

## 6. Test UDP

Avviare il server su NUC1 come nel test precedente, poi eseguire da NUC2:

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --interface enp114s0.28 \
  --port 5050 \
  --duration 30 \
  --udp \
  --bandwidth 400M
```

Modificare `--bandwidth` per provare altri carichi, ad esempio `100M`, `500M` o `600M`.

Nel test UDP interpretare insieme:

- bitrate ricevuto;
- jitter;
- percentuale di pacchetti persi.

Un bitrate elevato con packet loss elevato non indica un collegamento stabile.

## 7. Test nella direzione opposta

Per misurare NUC1 verso NUC2, invertire i ruoli.

### NUC2 server

```bash
network_monitor2 --server \
  --bind-ip 10.10.28.11 \
  --interface enp114s0.28 \
  --port 5050
```

### NUC1 client

```bash
network_monitor2 10.10.28.11 \
  --source-ip 10.10.28.10 \
  --interface enp114s0.28 \
  --port 5050 \
  --duration 30 \
  --tcp
```

## 8. Utilizzare TN1

Per TN1 sostituire indirizzi e interfacce TN0 con quelli VLAN29:

```text
NUC2: 10.10.29.11 — enp114s0.29
NUC1: 10.10.29.10 — enp114s0.29
```

Esempio server NUC1:

```bash
network_monitor2 --server \
  --bind-ip 10.10.29.10 \
  --interface enp114s0.29 \
  --port 5050
```

Esempio client NUC2:

```bash
network_monitor2 10.10.29.10 \
  --source-ip 10.10.29.11 \
  --interface enp114s0.29 \
  --port 5050 \
  --duration 30 \
  --tcp
```

## 9. Percorso attraverso i gateway CEIT

Quando il traffico deve attraversare CEIT, gli indirizzi di test sono:

```text
NUC2: 10.10.42.11 — enp114s0.42
NUC1: 10.10.22.10 — enp114s0.22
```

Dopo avere applicato le route CEIT previste, verificare il percorso:

```bash
ip route get 10.10.22.10 from 10.10.42.11
```

Il risultato su NUC2 deve indicare il gateway `10.10.42.41`. Sul NUC1 il percorso di ritorno deve utilizzare `10.10.22.40`.

Server su NUC1:

```bash
network_monitor2 --server \
  --bind-ip 10.10.22.10 \
  --interface enp114s0.22 \
  --port 5050
```

Client su NUC2:

```bash
network_monitor2 10.10.22.10 \
  --source-ip 10.10.42.11 \
  --interface enp114s0.42 \
  --port 5050 \
  --duration 30 \
  --tcp
```

La radio selezionata internamente dai gateway CEIT non può essere controllata o identificata dai NUC.

## 10. Come leggere i risultati a terminale

Per TCP, il riepilogo iperf3 mostra:

- transfer: quantità di dati trasferita;
- bitrate: throughput misurato;
- retr: segmenti TCP ritrasmessi.

Per UDP mostra:

- bitrate ricevuto;
- jitter;
- pacchetti persi e percentuale di loss.

Il tool stampa `Monitoring run completed` quando client, ping e monitoraggio delle interruzioni sono terminati correttamente.

## 11. Esportare i risultati in Excel

Per esportare tutti i dati locali:

```bash
network_monitor2 --export-excel results.xlsx
```

Per limitare l'esportazione a un intervallo temporale:

```bash
network_monitor2 --export-excel results.xlsx \
  --start "2026-07-23 09:00:00" \
  --end "2026-07-23 12:00:00"
```

Il file Excel contiene normalmente:

- `iperf_results`;
- `ping_results`;
- `interruptions`;
- `commands`.

Eseguire l'export sul NUC del quale si vogliono estrarre i dati locali.

## 12. Visualizzare i risultati in Grafana

Se Grafana è già configurato, aprire dal browser:

```text
http://<IP_DEL_SERVER_GRAFANA>:3000
```

Selezionare uno dei dashboard:

- Network Monitoring Dashboard, per i dati locali;
- Network Monitoring Dashboard (Bidirectional), per confrontare dati locali e remoti.

I pannelli principali mostrano throughput, jitter, packet loss, latenza, interruzioni e metadati del comando.

Se si utilizza lo stack Docker incluso nel repository:

```bash
cd /home/comsa/network_monitor_v2
cp .env.grafana.example .env.grafana
docker compose -f docker-compose.grafana.yml up -d
```

Le credenziali e le connessioni ai database sono definite in `.env.grafana`.

## 13. Problemi comuni

### Connection refused

Controllare che il server sia attivo, che client e server usino la stessa porta e che `--bind-ip` corrisponda all'indirizzo presente sul server.

### No route to host

Controllare:

```bash
ip route get <DESTINAZIONE> from <SORGENTE>
ip neigh
ping -I <SORGENTE> -c 5 <DESTINAZIONE>
```

Un neighbor in stato `FAILED` indica generalmente un problema ARP, VLAN o Layer 2.

### Nessun dato in Grafana

Verificare l'intervallo temporale del dashboard, la configurazione MariaDB in `/opt/network_monitor2/setup.conf` e che il test abbia mostrato `Monitoring run completed`.

### Porta già in uso

Usare un'altra porta sia sul server sia sul client:

```bash
network_monitor2 --server --bind-ip <IP_SERVER> --port 5051
network_monitor2 <IP_SERVER> --source-ip <IP_CLIENT> --port 5051 --tcp
```

## 14. Campagna KPI automatica

Per eseguire automaticamente la matrice CEIT, bypass TN0 e bypass TN1:

```bash
cd /home/comsa/network_monitor_v2
./run_kpi_tests.sh
```

Per controllare prima le operazioni senza modificare la rete:

```bash
./run_kpi_tests.sh --dry-run
```

La campagna genera una nuova cartella sotto `results/` con report Markdown/PDF, CSV, output completi dei test e log di routing.

## 15. Riferimento rapido

Mostrare l'help:

```bash
network_monitor2 --help
```

TCP:

```bash
network_monitor2 <IP_SERVER> --source-ip <IP_CLIENT> --duration 30 --tcp
```

UDP:

```bash
network_monitor2 <IP_SERVER> --source-ip <IP_CLIENT> \
  --duration 30 --udp --bandwidth 100M
```

Server:

```bash
network_monitor2 --server --bind-ip <IP_LOCALE> --port 5050
```

Export:

```bash
network_monitor2 --export-excel results.xlsx
```
