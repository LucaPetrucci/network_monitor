# Passaggio di consegne: permessi NUC e percorso INDRA

Per architettura, componenti e flussi generali leggere prima [il contesto del progetto](PROJECT_CONTEXT.md).

**Aggiornamento successivo:** il 9 novembre NUC2 è stato migrato a InfluxDB 2; NUC1 resta su MariaDB. Le prove storiche qui sotto descrivono lo stato del 5 novembre. Per codice, deployment e test più recenti vedere [migrazione](INFLUXDB_MIGRATION.md) e [validazione prima del commit](VALIDATION_20261109.md).

Documento preparato il **9 novembre 2026**. Interventi e prove di rete descritti sono del **5 novembre 2026**, salvo indicazione diversa. Il 9 novembre sono stati riletti i file locali e lo stato Git; **non è stato ripetuto il collaudo dei dispositivi**.

## Punto di ripartenza

Il problema originale di Jaime Resuela Bajo (INDRA), inoltrato da Xavi a Luca, era:

```text
/usr/local/bin/network_monitor2: line 16: /opt/network_monitor2/setup.conf: Permission denied
```

**Risolto su NUC1 e NUC2** tramite ACL di sola lettura per `tuser`, senza concedergli sudo. Verificato usando realmente `tuser` per server e client. Sulla rete di management il simulatore funziona in entrambi i versi e scrive nei DB locali.

**Ancora aperto:** il percorso attraverso i gateway INDRA non raggiunge il vero NUC1. NUC2 riceve un RST TCP e risposte ping che non compaiono nella cattura di NUC1. Nel verso opposto il gateway restituisce host unreachable. Non attribuire il RST a un apparato specifico senza ulteriori catture: non è stato identificato con certezza.

## Accesso, rete e vincoli dell'utente

Workspace su NUC2: `/home/comsa/network_monitor_v2`. Account di lavoro: `comsa`. Accesso verificato a NUC1 con `ssh comsa@10.10.27.10` e chiave SSH. Sudo richiede autenticazione; l'utente l'ha fornita durante la sessione. **Nessuna password va copiata in documenti, repository o log.** Se serve nuova autenticazione, usare il canale interattivo disponibile.

L'utente ha espressamente richiesto di **non dare sudo a `tuser`**. L'autorizzazione amministrativa serve all'operatore per correggere l'installazione, non al runtime.

| Nodo/percorso | NUC1 | NUC2 |
|---|---|---|
| Hostname | nuc1 | nuc2 |
| Management, VLAN27 | 10.10.27.10 | 10.10.27.11 |
| Interfaccia management | enp114s0 | enp114s0 |
| Endpoint test INDRA/CEIT | 10.10.22.10 | 10.10.42.11 |
| Interfaccia test | enp114s0.22 | enp114s0.42 |
| Gateway INDRA | 10.10.22.30 | 10.10.42.31 |
| Gateway CEIT, da guida | 10.10.22.40 | 10.10.42.41 |
| Bypass VLAN28 | 10.10.28.10 | 10.10.28.11 |
| Bypass VLAN29 | 10.10.29.10 | 10.10.29.11 |

Il percorso management è direttamente connesso e non collauda i gateway INDRA. Non cambiare VLAN27 o la route di default per diagnosticare il percorso di test. Non interrompere listener preesistenti: su NUC1 erano presenti anche `10.10.28.10:5050` e `*:5201`. Per queste prove è stata usata la porta 5051 dopo averne verificato la disponibilità.

## Correzione realmente applicata

Il launcher esegue `source` di `setup.conf` prima di analizzare le opzioni. L'errore iniziale precedeva quindi il bind. Il file era `root:comsa`, permessi 640; `tuser` non era nel gruppo `comsa` su nessun nodo.

Su **entrambi** i NUC è stato eseguito da amministratore:

```bash
sudo setfacl -m u:tuser:r /opt/network_monitor2/setup.conf
sudo -u tuser test -r /opt/network_monitor2/setup.conf
sudo -u tuser /usr/local/bin/network_monitor2 --help
```

Su NUC1 mancava `setfacl`: è stato installato il pacchetto Debian `acl`. NUC2 lo aveva già. Proprietario e gruppi degli utenti non sono stati cambiati. ACL verificata:

```text
user::rw-
user:tuser:r--
group::r--
mask::r--
other::---
```

Il file contiene credenziali DB: la lettura le rende disponibili al runtime `tuser`. Non usare chmod 644/777 e non stampare il contenuto nelle verifiche. La correzione persiste sul file, ma va ricontrollata se un'installazione lo sostituisce o altera la maschera ACL.

Lo script locale [scripts/grant_runtime_access.sh](../scripts/grant_runtime_access.sh) applica la stessa correzione e verifica leggibilità e help come utente runtime. Il file era ancora non tracciato al controllo del 9 novembre. Sintassi e rifiuto dell'esecuzione non-root sono stati verificati; l'intervento remoto su NUC1 è stato effettuato con comandi equivalenti, non distribuendo quello script.

Il comando della mail usava `--servidor` e `--puerto`: **non sono opzioni supportate**. Gli script installati accettano `--server` e `--port`. Non sono stati aggiunti alias spagnoli.

## Versioni e modifiche del repository

Non è stata fatta una reinstallazione generale e non sono stati aggiornati gli script runtime durante questo intervento. Nel controllo del 5 novembre gli SHA-256 coincidevano tra workspace NUC2 e installazioni di entrambi i NUC:

| Script | SHA-256 |
|---|---|
| server_launcher.sh | 9214c18750c62d4c3a42e48e16099bfb5eaef4592e7a67d39a4a6a3c29e5b909 |
| iperf_client.sh | 2ada54510af5446fc1720f6427cc80ec623d3ecdd633699f9894f5fd86431cc2 |

Questo confronto riguarda **solo questi due file**, non tutte le dipendenze o l'intera installazione. Il comando installato è un symlink a `/opt/network_monitor2/server_launcher.sh`.

All'inizio della conversazione erano già presenti modifiche locali a:

- `network_monitor/iperf_client.sh`: selezione degli intervalli UDP receiver in modalità reverse, distinguendo la sezione client da `Server output:`.
- `tests/test_network_monitor_options.sh`: aggiunta di una prova UDP reverse.

Non sono modifiche create dall'intervento sui permessi: conservarle e non annullarle. Non fu rieseguita la suite automatizzata durante quella correzione. All'inizio della documentazione del 9 novembre HEAD era `e78fc50` (`Update tool`), con quei due file modificati e `scripts/` non tracciata. Successivamente la correzione reverse e il test sono stati inclusi e verificati nell'attività di migrazione InfluxDB; vedere il documento di validazione per la pubblicazione.

## Collaudo management realmente eseguito

Server NUC1 e client NUC2 eseguiti come `tuser`, senza privilegi nel processo runtime. L'amministratore ha usato `runuser -u tuser -- ...` per impersonare l'utente. Comandi da eseguire direttamente nelle rispettive sessioni `tuser`:

NUC1:

```bash
network_monitor2 --server --bind-ip 10.10.27.10 --port 5051
```

NUC2, direzione normale:

```bash
network_monitor2 10.10.27.10 --source-ip 10.10.27.11 --port 5051 \
  --udp --bandwidth 1M --packet-size 1200 --duration 5
```

NUC2, traffico NUC1 → NUC2:

```bash
network_monitor2 10.10.27.10 --source-ip 10.10.27.11 --port 5051 \
  --udp --reverse --bandwidth 1M --packet-size 1200 --duration 5
```

| Prova finale | Risultato |
|---|---|
| UDP NUC2 → NUC1 | Exit 0, circa 1 Mbit/s, 521 datagrammi, 0 persi |
| UDP NUC1 → NUC2, --reverse | Exit 0, circa 1 Mbit/s, 521 datagrammi, 0 persi |
| Database locali | 10 campioni recenti iperf su ciascun nodo per le due prove |
| Route management | Diretta su enp114s0, nessun gateway INDRA |

I conteggi DB furono filtrati per intervallo temporale recente, metadata `port=5051` e indirizzo management. Sono evidenze storiche, non query da ripetere oggi aspettandosi gli stessi conteggi. Ogni nodo scrive nel proprio MariaDB. Le prove precedenti di 3 secondi avevano dato 313 datagrammi senza perdite.

I listener temporanei sono stati arrestati e le shell amministrative chiuse. Non è stato lasciato un servizio persistente in ascolto su 5051: per nuovi test bisogna avviare il server.

## Diagnosi INDRA: fatti e limiti

Route presenti e coerenti con gli script `/home/tuser/scripts/test_indra`:

```text
NUC2: 10.10.22.0/24 via 10.10.42.31 dev enp114s0.42
NUC1: 10.10.42.0/24 via 10.10.22.30 dev enp114s0.22
```

1. Avviato server come `tuser` su `10.10.22.10:5051`; `ss` confermava iperf3 in ascolto. Una prova locale su NUC1 era riuscita.
2. Cattura NUC2: SYN verso `10.10.22.10:5051`, poi RST/ACK proveniente apparentemente da quell'IP, TTL 59. Il MAC del next hop era `02:42:0a:0a:2a:1f`, associato a `10.10.42.31`. Il MAC identifica solo il next hop, non chi ha generato il RST.
3. Cattura NUC1 su **tutte** le interfacce, filtro `tcp port 5051 or icmp`, senza restrizioni sull'IP sorgente per non perdere traffico NAT: nessuna richiesta del test da NUC2.
4. Anche i ping INDRA con risposta positiva su NUC2 non compaiono su NUC1. Il ping da solo non dimostra quindi di aver raggiunto il dispositivo corretto.
5. Controllo positivo: i ping sulla management compaiono correttamente nella cattura NUC1; non si tratta semplicemente di una cattura non funzionante.
6. Prova inversa `ping -I 10.10.22.10 ... 10.10.42.11`: fallisce. La cattura NUC1 registra `ICMP host 10.10.42.11 unreachable` da `10.10.22.30`, insieme a ripetute richieste ARP di quel gateway per `10.10.22.1`.
7. Gateway lato NUC1: MAC `02:42:0a:0a:16:1e` per `10.10.22.30`. SSH porta 22 rifiutato sia da `.22.30` sia da `.42.31`.
8. `nft list ruleset`: nessuna regola di blocco osservata sui NUC; NUC1 aveva tabelle filter/nat vuote, NUC2 ruleset vuoto.

**Interpretazione:** problema nella rete intermedia INDRA; possibile instradamento/NAT/terminazione su endpoint diverso, ma nessuna di queste cause specifiche è stata dimostrata. L'ARP verso `.22.1` e l'host unreachable sono indizi concreti per chi può amministrare il gateway `.22.30`. Non è stata letta la tabella di routing del gateway e non sappiamo perché cerchi `.22.1`.

Non sono state cambiate route, firewall o configurazioni dei gateway. Non correggere le route documentate sui NUC sulla sola base di questi indizi.

## Evidenze e trasferibilità

File locali sotto `results/indra_permissions_20261105/`:

- `verification.md`: resoconto progressivo; le prime righe descrivono anche lo stato iniziale, poi corretto.
- `management_tuser_client.log`, `management_tuser_server.log`: primo test come tuser.
- `indra_diag_nuc1.txt`, `indra_diag_nuc2.txt`: catture con filtro ampio per INDRA.
- `indra_control_nuc1.txt`, `indra_control_nuc2.txt`: controllo management e prova inversa.
- `reply_xavi.md`: bozza iniziale, non inviata.

Prova finale bidirezionale: `results/management_verification_20261105/{udp.log,reverse.log,server.log}`.

**Attenzione:** `.gitignore` esclude `results*`, `*.log` e `docs/kpi_campaign`. Queste evidenze locali **non arrivano a un altro agente tramite un semplice clone**. Il presente documento in `docs/` contiene i risultati essenziali ed è tracciabile; per analisi dei pacchetti trasferire separatamente le catture necessarie, dopo averne controllato il contenuto. Non copiare `setup.conf` o credenziali per fare il passaggio di consegne.

## Come riprendere

1. Rileggere questo documento; controllare `git status --short` per preservare il lavoro preesistente.
2. Verificare stato attuale su entrambi i NUC: hostname, IP, route, `id tuser`, ACL con `getfacl`, disponibilità porta 5051 e hash degli script. Non assumere che lo stato del 5 novembre sia ancora identico.
3. Verificare `sudo -u tuser test -r /opt/network_monitor2/setup.conf` e `sudo -u tuser network_monitor2 --help`; non stampare configurazioni o password.
4. Se serve confermare il runtime, ripetere il collaudo management sopra con traffico limitato, salvare nuovi log datati e arrestare solo il server di prova appena creato.
5. Per INDRA, ottenere l'accesso amministrativo previsto ai gateway o al sistema che li ospita. La sola coppia di credenziali dei NUC non dimostra l'accesso a quei dispositivi. Controllare route verso i due endpoint, NAT, eventuali IP duplicati/endpoint emulati e percorso di ritorno.
6. Catturare simultaneamente sui due NUC e sui gateway, correlando IP/porte/sequence TCP e identificativi ICMP. Sul NUC1 usare un filtro senza IP sorgente, per includere eventuale NAT. Verificare il motivo dell'ARP verso `10.10.22.1` prima di cambiare configurazioni.
7. Dopo una correzione verificabile, ripetere UDP nei due versi come tuser sul percorso INDRA, controllare DB e aggiornare questo resoconto con nuove evidenze.

## Comunicazione a Xavi

È stata preparata una risposta in inglese, **non inviata dall'agente**. Contenuto corretto da mantenere:

- Permessi risolti su entrambi i NUC; tuser non ha ricevuto sudo.
- Usare `--server` e `--port`.
- Simulatore verificato sulla management `10.10.27.10 ↔ 10.10.27.11`, entrambe le direzioni, zero perdite e dati nei DB.
- Percorso gateway INDRA ancora guasto; la management permette di dimostrare il funzionamento del tool, ma non equivale al collaudo del percorso INDRA.

Non scrivere che tutto il sistema INDRA è risolto o che sono stati aggiornati tutti i tool: non sarebbe supportato dalle prove.
