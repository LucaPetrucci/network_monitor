# Guida a un test manuale personalizzato

Questa guida serve a eseguire un singolo test con parametri diversi dalle matrici automatiche. Presuppone che `network_monitor2` sia già installato e configurato su NUC1 e NUC2.

> **Sicurezza:** non modificare VLAN27, `enp114s0`, gli indirizzi di management o la route di default. NUC1 deve essere raggiunto tramite management all'indirizzo `10.10.27.10`.

## 1. Definire il test

Prima di iniziare, scegliere percorso, direzione del traffico, protocollo, porta, durata, numero di flussi, packet size e, per TCP, window size oppure, per UDP, bandwidth offerta.

Annotare anche il percorso attivo prima del test, in modo da poterlo ripristinare alla fine:

```bash
ip route show 10.10.22.0/24
ssh 10.10.27.10 'ip route show 10.10.42.0/24'
```

| Percorso | IP NUC2 | IP NUC1 |
|---|---|---|
| CEIT | `10.10.42.11` | `10.10.22.10` |
| INDRA | `10.10.42.11` | `10.10.22.10` |
| Bypass TN0 | `10.10.28.11` | `10.10.28.10` |
| Bypass TN1 | `10.10.29.11` | `10.10.29.10` |

CEIT e INDRA usano gli stessi endpoint ma gateway diversi.

## 2. Selezionare il percorso

### CEIT

Da NUC2:

```bash
sudo /home/tuser/scripts/test_ceit
ssh -t 10.10.27.10 'sudo /home/tuser/scripts/test_ceit'

ip route get 10.10.22.10 from 10.10.42.11
ssh 10.10.27.10 'ip route get 10.10.42.11 from 10.10.22.10'
```

Il primo risultato deve usare il gateway `10.10.42.41`; il secondo `10.10.22.40`.

### INDRA

Da NUC2:

```bash
sudo /home/tuser/scripts/test_indra
ssh -t 10.10.27.10 'sudo /home/tuser/scripts/test_indra'

ip route get 10.10.22.10 from 10.10.42.11
ssh 10.10.27.10 'ip route get 10.10.42.11 from 10.10.22.10'
```

Il primo risultato deve usare il gateway `10.10.42.31`; il secondo `10.10.22.30`.

### Bypass TN0 o TN1

Rimuovere soltanto le route di test CEIT/INDRA:

```bash
sudo ip route del 10.10.22.0/24 via 10.10.42.41 2>/dev/null || true
sudo ip route del 10.10.22.0/24 via 10.10.42.31 2>/dev/null || true

ssh -t 10.10.27.10 \
  'sudo ip route del 10.10.42.0/24 via 10.10.22.40 2>/dev/null || true;
   sudo ip route del 10.10.42.0/24 via 10.10.22.30 2>/dev/null || true'
```

Controllare il bypass scelto:

```bash
# TN0
ip route get 10.10.28.10 from 10.10.28.11

# TN1
ip route get 10.10.29.10 from 10.10.29.11
```

Il risultato deve mostrare una route direttamente connessa, senza gateway.

## 3. Verificare la raggiungibilità

```bash
ping -I <IP_NUC2> -c 5 <IP_NUC1>
```

Esempio TN0:

```bash
ping -I 10.10.28.11 -c 5 10.10.28.10
```

Se il risultato è `100% packet loss`, non avviare il test. Controllare route, VLAN e ARP.

## 4. Scegliere la direzione

Senza `--reverse`, il traffico va dal client NUC2 al server NUC1. Con `--reverse`, il server genera il traffico verso il client, mantenendo comunque i risultati client nel database di NUC2.

In alternativa è possibile scambiare fisicamente i ruoli server/client, se si vuole che NUC1 sia il client che registra il test.

## 5. Avviare il server

In un terminale collegato a NUC1:

```bash
ssh 10.10.27.10
network_monitor2 --server --bind-ip <IP_NUC1> --port <PORTA>
```

Esempio TN0 sulla porta `5051`:

```bash
ss -ltn | grep -q ':5051 ' && echo 'PORTA OCCUPATA' || echo 'PORTA LIBERA'
network_monitor2 --server --bind-ip 10.10.28.10 --port 5051
```

Lasciare il server attivo. Se compare `Address already in use`, scegliere un'altra porta sia sul server sia sul client.

## 6. Costruire il comando personalizzato

```bash
network_monitor2 <IP_NUC1> \
  --source-ip <IP_NUC2> \
  --port <PORTA> \
  --duration <SECONDI> \
  --tcp|--udp \
  [--bandwidth <RATE>] \
  [--packet-size <BYTE>] \
  [--window-size <SIZE>] \
  [--flows <1-32>] \
  [--reverse]
```

| Parametro | Effetto |
|---|---|
| `--duration` | Durata del test; predefinita `30` secondi |
| `--tcp` | Test TCP |
| `--udp` | Test UDP; è il protocollo predefinito |
| `--bandwidth` | Traffico UDP totale offerto, per esempio `75M` o `1G` |
| `--packet-size` | Datagram size UDP (`iperf3 -l`) o TCP MSS (`iperf3 -M`); default `1460` byte |
| `--window-size` | Socket buffer/window TCP, per esempio `256K` o `1M`; solo TCP |
| `--flows` | Flussi paralleli, da 1 a 32; predefinito 1 |
| `--reverse` | Traffico dal server NUC1 verso il client NUC2 |

Con UDP e più flussi, la bandwidth totale viene divisa automaticamente. Per esempio, `--bandwidth 200M --flows 4` genera quattro flussi da `50M`.

La porta deve essere compresa tra `1` e `65535`. Per UDP, scegliere il packet size tenendo conto dell'MTU del percorso: valori troppo grandi possono introdurre frammentazione, che va usata solo se fa parte del test.

Se `--packet-size` viene omesso, il tool passa comunque a `iperf3` e salva il default esplicito `1460`. In questo modo i nuovi risultati non hanno `packet_size=NULL`. Con MTU 1500, non usare un MSS TCP superiore a `1460`.

Con più flussi TCP, `--window-size` viene applicato a ciascun flusso. Il valore effettivo può essere limitato dalle impostazioni massime dei socket buffer del sistema operativo.

I due NUC sono configurati per accettare window size fino a `1M` tramite limiti socket da 4 MiB. Prima del test è possibile verificarli senza modificare il sistema:

```bash
cat /proc/sys/net/core/rmem_max
cat /proc/sys/net/core/wmem_max
```

Entrambi devono mostrare `4194304` su NUC1 e NUC2.

## 7. Esempi ad hoc

### TCP NUC2 → NUC1, durata 45 secondi

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 45 --tcp
```

### TCP NUC1 → NUC2, 8 flussi e MSS da 1400 byte

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 45 --tcp \
  --reverse --flows 8 --packet-size 1400
```

### TCP con window size da 64 KiB

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 60 --tcp \
  --window-size 64K
```

### TCP con window size da 1 MiB

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 60 --tcp \
  --window-size 1M
```

### UDP a 75 Mbit/s con datagrammi da 1000 byte

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 90 --udp \
  --bandwidth 75M --packet-size 1000
```

### UDP reverse a 200 Mbit/s complessivi su quattro flussi

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 60 --udp \
  --bandwidth 200M --flows 4 --reverse
```

Per CEIT, INDRA o TN1 cambiare soltanto `IP_NUC1` e `IP_NUC2` secondo la tabella iniziale.

### I due test richiesti

Con server TN0 attivo sulla porta `5051`, eseguire da NUC2:

```bash
# UDP 500 Mbit/s: valutare soprattutto lost_percentage del receiver
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 120 --udp --bandwidth 500M

# TCP con socket/window da 1 MiB: valutare soprattutto il throughput receiver
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5051 --duration 120 --tcp --window-size 1M
```

Per UDP il tool acquisisce l'output receiver del server, quindi `lost_percentage` nel DB, in Excel e in Grafana rappresenta la perdita ricevuta e non lo zero riportato dal sender.

## 8. Verificare il risultato

`Monitoring run completed` indica che il comando è terminato. Verificare comunque:

- TCP: bitrate e ritrasmissioni `Retr` nel terminale;
- UDP: bitrate ricevuto, jitter e percentuale di pacchetti persi;
- test multi-flusso: riga aggregata `[SUM]`;
- reverse: direzione effettiva NUC1 → NUC2.

Per vedere le ultime righe nel database locale del client:

```bash
mysql -h <DB_HOST> -P <DB_PORT> -u <DB_USER> -p <DB_NAME> -e "
SELECT timestamp, bitrate, jitter, lost_percentage,
       protocol, packet_size, window_size, executed_command
FROM iperf_results
ORDER BY id DESC
LIMIT 20;"
```

In `executed_command` controllare IP, porta, protocollo, durata, direzione, numero di flussi e window size. In alternativa aprire Grafana, selezionare gli ultimi 15 minuti e consultare il dashboard locale o bidirezionale.

## 9. Esportare soltanto il test eseguito

Nello stesso terminale del client, acquisire l'ora subito prima del test:

```bash
TEST_START="$(date '+%F %T')"
```

Eseguire il comando personalizzato e, appena termina, acquisire la fine:

```bash
TEST_END="$(date '+%F %T')"
printf 'Intervallo test: %s .. %s\n' "$TEST_START" "$TEST_END"
```

Costruire il nome usando gli stessi timestamp ed esportare esattamente quell'intervallo:

```bash
TEST_START_FILE="$(date -d "$TEST_START" '+%Y%m%d_%H%M%S')"
TEST_END_FILE="$(date -d "$TEST_END" '+%Y%m%d_%H%M%S')"
EXPORT_FILE="test_personalizzato_${TEST_START_FILE}_to_${TEST_END_FILE}.xlsx"

network_monitor2 --export-excel "$EXPORT_FILE" \
  --start "$TEST_START" \
  --end "$TEST_END"

printf 'File esportato: %s\n' "$EXPORT_FILE"
```

Il nome risultante, per esempio `test_personalizzato_20260908_101500_to_20260908_101545.xlsx`, identifica senza ambiguità l'inizio e la fine del test.

L'exporter applica automaticamente lo stesso suffisso quando riceve sia `--start` sia `--end`; se il nome lo contiene già, non lo duplica.

## 10. Terminare

Fermare il server con `Ctrl+C`. Verificare che non sia rimasto attivo sulla porta scelta:

```bash
pgrep -af 'iperf3.*-s'
```

Ripristinare il percorso annotato al punto 1. Se prima era attivo CEIT o INDRA, eseguire il relativo script su entrambi i NUC; se era già attivo un bypass, lasciare assenti le route CEIT/INDRA. Infine ripetere i due comandi `ip route show` del punto 1 e confrontare il risultato.
