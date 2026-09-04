# Guida operativa a network_monitor2

Questa guida descrive la procedura minima per scegliere un percorso ed eseguire un test tra NUC2 e NUC1. Per installazione, database e opzioni avanzate consultare il `README.md`.

## 1. Prima di iniziare

> **Sicurezza:** non modificare o interrompere mai la connessione di management su VLAN27.

- NUC2 management: `10.10.27.11`, interfaccia `enp114s0`.
- NUC1 management: `10.10.27.10`, interfaccia `enp114s0`.
- Gateway di default: `10.10.27.1` su `enp114s0`.
- Collegarsi a NUC1 tramite `ssh 10.10.27.10`.

Non modificare VLAN27, gli indirizzi di management o la route di default.

Verificare il tool su entrambi i NUC:

```bash
command -v network_monitor2
network_monitor2 --help
command -v iperf3
```

## 2. Scegliere il percorso

- **CEIT:** NUC2 `10.10.42.11` → NUC1 `10.10.22.10`.
- **INDRA:** NUC2 `10.10.42.11` → NUC1 `10.10.22.10`.
- **Bypass TN0:** NUC2 `10.10.28.11` → NUC1 `10.10.28.10`.
- **Bypass TN1:** NUC2 `10.10.29.11` → NUC1 `10.10.29.10`.

CEIT e INDRA usano gli stessi indirizzi terminali, ma route e gateway diversi. I bypass sono direttamente connessi.

### CEIT

Da NUC2, selezionare CEIT su entrambi i NUC:

```bash
sudo /home/tuser/scripts/test_ceit
ssh -t 10.10.27.10 'sudo /home/tuser/scripts/test_ceit'
```

```bash
# NUC2: deve mostrare via 10.10.42.41
ip route get 10.10.22.10 from 10.10.42.11

# NUC1: deve mostrare via 10.10.22.40
ssh 10.10.27.10 \
  'ip route get 10.10.42.11 from 10.10.22.10'
```

### INDRA

Da NUC2, selezionare INDRA su entrambi i NUC:

```bash
sudo /home/tuser/scripts/test_indra
ssh -t 10.10.27.10 'sudo /home/tuser/scripts/test_indra'
```

```bash
# NUC2: deve mostrare via 10.10.42.31
ip route get 10.10.22.10 from 10.10.42.11

# NUC1: deve mostrare via 10.10.22.30
ssh 10.10.27.10 \
  'ip route get 10.10.42.11 from 10.10.22.10'
```

### Bypass TN0 o TN1

Non esiste uno script `test_bypass`. Prima del bypass eliminare le sole route di test CEIT/INDRA. Questi comandi non devono modificare VLAN27 o la route di default:

```bash
# NUC2
sudo ip route del 10.10.22.0/24 via 10.10.42.41 2>/dev/null || true
sudo ip route del 10.10.22.0/24 via 10.10.42.31 2>/dev/null || true

# NUC1, via management
ssh -t 10.10.27.10 \
  'sudo ip route del 10.10.42.0/24 via 10.10.22.40 2>/dev/null || true; \
   sudo ip route del 10.10.42.0/24 via 10.10.22.30 2>/dev/null || true'
```

Controllare il percorso scelto:

```bash
# TN0
ip route get 10.10.28.10 from 10.10.28.11

# TN1
ip route get 10.10.29.10 from 10.10.29.11
```

Il risultato deve indicare una route direttamente connessa, senza gateway. Per tornare a CEIT o INDRA, rieseguire il relativo script su entrambi i NUC.

## 3. Verificare la raggiungibilità

Da NUC2 eseguire il ping relativo al percorso scelto:

```bash
# CEIT o INDRA
ping -I 10.10.42.11 -c 5 10.10.22.10

# Bypass TN0
ping -I 10.10.28.11 -c 5 10.10.28.10

# Bypass TN1
ping -I 10.10.29.11 -c 5 10.10.29.10
```

Se il ping restituisce `100% packet loss`, non eseguire il test di throughput. Controllare prima route, indirizzi, VLAN e ARP.

## 4. Eseguire un test TCP

Servono due terminali. Avviare prima il server su NUC1 e poi il client su NUC2. Questo esempio usa TN0.

### Terminale 1 — server su NUC1

```bash
ssh 10.10.27.10
network_monitor2 --server \
  --bind-ip 10.10.28.10 \
  --port 5050
```

Lasciare il server attivo.

### Terminale 2 — client su NUC2

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5050 \
  --duration 30 \
  --tcp
```

`Monitoring run completed` indica che throughput, ping e monitoraggio delle interruzioni sono terminati. Il client salva i risultati nel database locale di NUC2; il server salva localmente i propri campioni iperf3.

Al termine fermare il server con `Ctrl+C`.

## 5. Adattare il comando al percorso

Cambiano solo gli indirizzi:

- **CEIT o INDRA:** server `10.10.22.10`, client/source `10.10.42.11`.
- **TN0:** server `10.10.28.10`, client/source `10.10.28.11`.
- **TN1:** server `10.10.29.10`, client/source `10.10.29.11`.

Usare sempre `--bind-ip` sul server e `--source-ip` sul client. `--interface` è facoltativo e serve come indicazione aggiuntiva o metadato.

## 6. Test UDP

Lasciare attivo lo stesso server, usare `--udp` e indicare il traffico da generare:

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5050 \
  --duration 30 \
  --udp \
  --bandwidth 400M
```

Per UDP valutare insieme bitrate ricevuto, jitter e percentuale di pacchetti persi. Un bitrate elevato con molte perdite non indica un collegamento stabile.

## 7. Test da NUC1 verso NUC2

Invertire server e client. Esempio TN0:

Su NUC2:

```bash
network_monitor2 --server --bind-ip 10.10.28.11 --port 5050
```

Su NUC1:

```bash
network_monitor2 10.10.28.11 \
  --source-ip 10.10.28.10 \
  --port 5050 --duration 30 --tcp
```

## 8. Consultare i risultati

### Terminale

Per TCP controllare throughput e ritrasmissioni (`Retr`). Per UDP controllare bitrate ricevuto, jitter e packet loss.

### Excel

Ogni NUC esporta il proprio database locale:

```bash
network_monitor2 --export-excel results.xlsx
```

Per limitare l'intervallo:

```bash
network_monitor2 --export-excel results.xlsx \
  --start "2026-09-03 09:00:00" \
  --end "2026-09-03 12:00:00"
```

### Grafana

Aprire `http://<IP_GRAFANA>:3000` e scegliere il dashboard locale o bidirezionale. Controllare l'intervallo temporale se non compaiono dati.

## 9. Campagna KPI automatica

Da NUC2 eseguire prima l'anteprima:

```bash
cd /home/comsa/network_monitor_v2
./run_kpi_tests.sh --dry-run
```

Poi avviare la campagna:

```bash
./run_kpi_tests.sh
```

La campagna attuale prova CEIT, bypass TN0 e bypass TN1, genera report e log sotto `results/` e ripristina lo stato iniziale delle route dopo successo, errore o `Ctrl+C`. **INDRA non è ancora incluso nella campagna automatica.**

## 10. Problemi comuni

### `Connection refused`

Verificare che il server sia attivo e che server e client usino la stessa porta.

### `No route to host` o ping senza risposta

```bash
ip route get <DESTINAZIONE> from <SORGENTE>
ip neigh
ping -I <SORGENTE> -c 5 <DESTINAZIONE>
```

Un neighbor `FAILED` indica normalmente un problema ARP, VLAN o Layer 2.

### Porta già occupata

Scegliere un'altra porta, per esempio `5051`, e usarla sia sul server sia sul client.

### Nessun dato in Grafana

Controllare intervallo temporale, `/opt/network_monitor2/setup.conf` e che il test abbia mostrato `Monitoring run completed`.

## Riferimento rapido

```bash
# Server
network_monitor2 --server --bind-ip <IP_LOCALE> --port 5050

# Client TCP
network_monitor2 <IP_SERVER> --source-ip <IP_CLIENT> \
  --port 5050 --duration 30 --tcp

# Client UDP
network_monitor2 <IP_SERVER> --source-ip <IP_CLIENT> \
  --port 5050 --duration 30 --udp --bandwidth 100M

# Export locale
network_monitor2 --export-excel results.xlsx
```
