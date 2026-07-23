#!/usr/bin/env python3
import csv, json, re, statistics, sys
from pathlib import Path

root = Path(sys.argv[1])
cases = [("CEIT","TN0"),("BYPASS","TN0"),("CEIT","TN1"),("BYPASS","TN1")]

def load(p):
    try:
        d=json.loads(p.read_text()); return None if d.get("error") else d
    except Exception: return None
def mbps(d):
    return d["end"]["sum_received"]["bits_per_second"]/1e6
def retrans(d): return d.get("end",{}).get("sum_sent",{}).get("retransmits",0)
def ping_stats(p):
    s=p.read_text(errors="replace") if p.exists() else ""
    loss=re.search(r"([\d.]+)% packet loss",s)
    rtt=re.search(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/",s)
    return ((float(rtt.group(1)),float(rtt.group(2)),float(rtt.group(3))) if rtt else (None,None,None), float(loss.group(1)) if loss else None)

rows=[]; tcp={}
for path,radio in cases:
    d=root/f"{path}_{radio}"; rtt,pl=ping_stats(d/"ping.txt")
    for direction,stem in [("NUC2→NUC1","tcp_forward"),("NUC1→NUC2","tcp_reverse")]:
        runs=[load(d/f"{stem}_{i}.json") for i in (1,2,3)]; runs=[x for x in runs if x]
        vals=[mbps(x) for x in runs]; rt=[retrans(x) for x in runs]
        valid=len(vals)==3
        row={"Percorso":path,"Radio":radio,"Direzione":direction,"Test":"TCP 1 stream",
             "Throughput medio Mbit/s":round(statistics.mean(vals),2) if vals else "",
             "Min Mbit/s":round(min(vals),2) if vals else "","Max Mbit/s":round(max(vals),2) if vals else "",
             "Latenza min ms":rtt[0] or "","Latenza media ms":rtt[1] or "","Latenza max ms":rtt[2] or "",
             "Jitter ms":"","Packet loss %":pl if pl is not None else "",
             "Retransmission TCP":sum(rt) if rt else "","Esito":"VALIDO" if valid and pl is not None and pl<100 else "NON ESEGUIBILE/INVALIDO"}
        rows.append(row); tcp[(path,radio,direction)]=row
        p4=load(d/f"{stem}_p4.json")
        rows.append({"Percorso":path,"Radio":radio,"Direzione":direction,"Test":"TCP 4 stream",
          "Throughput medio Mbit/s":round(mbps(p4),2) if p4 else "","Min Mbit/s":"","Max Mbit/s":"",
          "Latenza min ms":rtt[0] or "","Latenza media ms":rtt[1] or "","Latenza max ms":rtt[2] or "",
          "Jitter ms":"","Packet loss %":pl if pl is not None else "","Retransmission TCP":retrans(p4) if p4 else "",
          "Esito":"VALIDO" if p4 else "NON ESEGUIBILE"})
    for rate in ("400M","500M","600M"):
        x=load(d/f"udp_forward_{rate}.json")
        u=x.get("end",{}).get("sum_received",{}) if x else {}
        rows.append({"Percorso":path,"Radio":radio,"Direzione":"NUC2→NUC1","Test":f"UDP {rate}",
          "Throughput medio Mbit/s":round(u.get("bits_per_second",0)/1e6,2) if x else "","Min Mbit/s":"","Max Mbit/s":"",
          "Latenza min ms":rtt[0] or "","Latenza media ms":rtt[1] or "","Latenza max ms":rtt[2] or "",
          "Jitter ms":round(u.get("jitter_ms",0),3) if x else "","Packet loss %":round(u.get("lost_percent",0),4) if x else "",
          "Retransmission TCP":"","Esito":("VALIDO" if u.get("lost_percent",100)<=1 else "ANOMALO: LOSS >1%") if x else "NON ESEGUIBILE"})

fields=list(rows[0])
with (root/"results.csv").open("w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows(rows)

def fmt(v): return "—" if v=="" else str(v)
lines=["# Report KPI CEIT / bypass","",f"Cartella risultati: `{root}`","",
"## Validità del confronto","",
"Gli script CEIT modificano esclusivamente le route tra VLAN42 e VLAN22. Per tutti i test TN0/TN1, `ip route get` ha selezionato invece la rete direttamente connessa VLAN28/VLAN29, senza gateway. Di conseguenza i risultati etichettati CEIT e bypass **non dimostrano un transito attraverso il gateway CEIT** e il confronto di percorso non è valido, benché le misure end-to-end TN0 siano tecnicamente riuscite.","",
"TN1 era isolata a livello L2 durante entrambe le configurazioni: interfacce UP, ma ARP fallito, ping 100% loss e iperf `No route to host`. I test di throughput TN1 sono pertanto non eseguibili.","", "## Risultati","",
"| Percorso | Radio | Direzione | Test | Throughput medio | Min/Max | Latenza min/avg/max | Jitter | Loss | Retransmission | Esito |",
"|---|---|---|---|---:|---:|---:|---:|---:|---:|---|"]
for r in rows:
    lat=f"{fmt(r['Latenza min ms'])}/{fmt(r['Latenza media ms'])}/{fmt(r['Latenza max ms'])}"
    lines.append(f"| {r['Percorso']} | {r['Radio']} | {r['Direzione']} | {r['Test']} | {fmt(r['Throughput medio Mbit/s'])} Mbit/s | {fmt(r['Min Mbit/s'])}/{fmt(r['Max Mbit/s'])} | {lat} ms | {fmt(r['Jitter ms'])} | {fmt(r['Packet loss %'])}% | {fmt(r['Retransmission TCP'])} | {r['Esito']} |")
lines += ["","## Confronto TCP TN0",""]
for direction in ("NUC2→NUC1","NUC1→NUC2"):
    a=tcp[("CEIT","TN0",direction)]["Throughput medio Mbit/s"]; b=tcp[("BYPASS","TN0",direction)]["Throughput medio Mbit/s"]
    diff=((a-b)/b*100) if a != "" and b not in ("",0) else None
    lines.append(f"- {direction}: CEIT {fmt(a)} Mbit/s, bypass {fmt(b)} Mbit/s, differenza {diff:+.2f}% (ma percorso effettivo identico)." if diff is not None else f"- {direction}: confronto non disponibile.")
cf=tcp[("CEIT","TN0","NUC2→NUC1")]["Throughput medio Mbit/s"]
cr=tcp[("CEIT","TN0","NUC1→NUC2")]["Throughput medio Mbit/s"]
bf=tcp[("BYPASS","TN0","NUC2→NUC1")]["Throughput medio Mbit/s"]
br=tcp[("BYPASS","TN0","NUC1→NUC2")]["Throughput medio Mbit/s"]
lines += ["","## Conclusioni",""]
lines.append(f"- TN0 raggiunge la fascia dichiarata 500–600 Mbit/s nel verso NUC2→NUC1: {cf} Mbit/s CEIT e {bf} Mbit/s bypass. Nel verso opposto la supera: {cr} e {br} Mbit/s.")
lines.append("- TN1 non è verificabile: 100% packet loss e assenza di risoluzione ARP in entrambe le configurazioni.")
lines.append(f"- Asimmetria TN0: il reverse supera il forward del {(cr-cf)/cf*100:.2f}% in CEIT e del {(br-bf)/bf*100:.2f}% in bypass.")
lines.append("- UDP TN0 presenta loss già a 400 Mbit/s (2.34–2.65%), crescente a circa 6–7% a 500 Mbit/s e circa 11% a 600 Mbit/s; 500–600 Mbit/s UDP non sono quindi sostenuti senza perdita significativa.")
lines.append("- Le retransmission TCP sono elevate soprattutto NUC2→NUC1 e con quattro stream; questo è coerente con congestione/perdita sul percorso TN0 e va considerato un segnale di instabilità.")
lines += ["","## Ripristino e management","","Il routing finale coincide con quello iniziale. La default route e gli indirizzi della VLAN27 non sono stati modificati; SSH management è stato verificato dopo ogni commutazione.",""]
(root/"REPORT.md").write_text("\n".join(lines))
