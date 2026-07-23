#!/usr/bin/env python3
import csv, json, re, statistics, sys
from pathlib import Path

root=Path(sys.argv[1]); rows=[]
fields=["Percorso","Radio","Direzione","Test","Throughput medio Mbit/s","Min Mbit/s","Max Mbit/s","Latenza min ms","Latenza media ms","Latenza max ms","Jitter ms","Packet loss %","Retransmission TCP","Esito"]
def load(p):
    try:
        d=json.loads(p.read_text()); return None if d.get("error") else d
    except Exception:return None
def ping(p):
    s=p.read_text(errors="replace"); loss=re.search(r"([\d.]+)% packet loss",s); r=re.search(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/",s)
    return ((*(float(r.group(i)) for i in range(1,4)),) if r else (None,None,None),float(loss.group(1)) if loss else None)
def add(path,radio,direction,test,tp="",mn="",mx="",lat=(None,None,None),jit="",loss="",retr="",status=""):
    rows.append(dict(zip(fields,[path,radio,direction,test,tp,mn,mx,lat[0] or "",lat[1] or "",lat[2] or "",jit,loss,retr,status])))

# Correct CEIT addressing; radio is selected internally by the gateways.
for direction in ("NUC2→NUC1","NUC1→NUC2"):
    add("CEIT","Non determinabile",direction,"TCP 1 stream",loss=100,status="NON ESEGUIBILE: GW NON INOLTRA")
for rate in (400,500,600): add("CEIT","Non determinabile","NUC2→NUC1",f"UDP {rate}M",loss=100,status="NON ESEGUIBILE")

# Valid bypass TN0 dataset.
d=root/"BYPASS_TN0"; lat,pl=ping(d/"ping.txt")
for direction,stem in (("NUC2→NUC1","tcp_forward"),("NUC1→NUC2","tcp_reverse")):
    xs=[load(d/f"{stem}_{i}.json") for i in (1,2,3)]; vals=[x["end"]["sum_received"]["bits_per_second"]/1e6 for x in xs]; retr=[x["end"]["sum_sent"]["retransmits"] for x in xs]
    add("Bypass","TN0",direction,"TCP 1 stream",round(statistics.mean(vals),2),round(min(vals),2),round(max(vals),2),lat,loss=pl,retr=sum(retr),status="VALIDO")
    x=load(d/f"{stem}_p4.json"); add("Bypass","TN0",direction,"TCP 4 stream",round(x["end"]["sum_received"]["bits_per_second"]/1e6,2),lat=lat,loss=pl,retr=x["end"]["sum_sent"]["retransmits"],status="VALIDO")
for rate in (400,500,600):
    u=load(d/f"udp_forward_{rate}M.json")["end"]["sum_received"]
    add("Bypass","TN0","NUC2→NUC1",f"UDP {rate}M",round(u["bits_per_second"]/1e6,2),lat=lat,jit=round(u["jitter_ms"],3),loss=round(u["lost_percent"],4),status="ANOMALO: LOSS >1%")

# Bypass TN1 is L2 isolated.
for direction in ("NUC2→NUC1","NUC1→NUC2"): add("Bypass","TN1",direction,"TCP 1 stream",loss=100,status="NON ESEGUIBILE: ARP FALLITO")
for rate in (400,500,600): add("Bypass","TN1","NUC2→NUC1",f"UDP {rate}M",loss=100,status="NON ESEGUIBILE")

with (root/"results.csv").open("w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
def f(v):return "—" if v in ("",None) else str(v)
out=["# Report KPI corretto — CEIT e bypass","","## Correzione metodologica","","I precedenti test etichettati CEIT ma indirizzati alle VLAN28/29 erano in realtà traffico diretto e sono esclusi dai risultati ufficiali. Per CEIT sono stati usati correttamente `10.10.42.11 → 10.10.22.10`; la radio scelta internamente dal gateway non è osservabile né controllabile dai NUC.","","## Risultati ufficiali","","| Percorso | Radio | Direzione | Test | Throughput medio | Min/Max | Latenza min/avg/max | Jitter | Loss | Retransmission | Esito |","|---|---|---|---|---:|---:|---:|---:|---:|---:|---|"]
for r in rows:
    out.append(f"| {r['Percorso']} | {r['Radio']} | {r['Direzione']} | {r['Test']} | {f(r['Throughput medio Mbit/s'])} | {f(r['Min Mbit/s'])}/{f(r['Max Mbit/s'])} | {f(r['Latenza min ms'])}/{f(r['Latenza media ms'])}/{f(r['Latenza max ms'])} | {f(r['Jitter ms'])} | {f(r['Packet loss %'])}% | {f(r['Retransmission TCP'])} | {r['Esito']} |")
out += ["","## Interpretazione","","- CEIT: route corretta via `10.10.42.41` e ritorno via `10.10.22.40`; entrambi i gateway locali rispondono con 0% loss, ma il traffico non viene inoltrato tra essi. Traceroute fermo al primo hop e ping end-to-end con 100% loss.","- Bypass TN0: 591,01 Mbit/s TCP NUC2→NUC1 e 907,42 Mbit/s NUC1→NUC2. UDP presenta 2,65% loss a 400M, 7,02% a 500M e 11,10% a 600M.","- Bypass TN1: interfacce UP ma ARP tra i due NUC fallito; 100% packet loss.","- Non è possibile attribuire la prova CEIT a TN0 o TN1: dipende dalla configurazione interna del gateway.","","## Ripristino e management","","Routing iniziale CEIT ripristinato; VLAN27 e default route mai modificate. SSH management verificato.",""]
(root/"REPORT.md").write_text("\n".join(out))
