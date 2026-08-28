#!/usr/bin/env python3
"""Join WOZ batch results against the defect map -> per-defect pass rates.
Usage: join.py <results.csv> [defect_map.csv]"""
import csv,sys,collections
res=sys.argv[1]; dm=sys.argv[2] if len(sys.argv)>2 else 'woz_defect_map.csv'
D=['P0_timing','P1_tmap','P2_weak','P3_writ','P4_angular']
defect={r['file']:r for r in csv.DictReader(open(dm))}
status={}
for r in csv.reader(open(res)):
    if not r or r[0]=='status': continue
    f=r[5].strip('"').replace('woztest/','')
    status[f]=r[0]
print("results rows: %d\n"%len(status))
def rate(files):
    c=collections.Counter(status[f] for f in files if f in status)
    n=sum(c.values())
    return n,c
print("%-14s %6s %7s %7s %7s %7s"%("bucket","n","BOOTED","TEXT","BLANK","%boot"))
def row(label,files):
    n,c=rate(files)
    if not n: return
    print("%-14s %6d %7d %7d %7d %6.1f%%"%(label,n,c['BOOTED'],c['TEXT_ONLY'],c['BLANK'],100*c['BOOTED']/n))
for d in D:
    row(d,[f for f,r in defect.items() if r[d]=='1'])
row("ANY defect",[f for f,r in defect.items() if any(r[d]=='1' for d in D)])
row("CONTROL",[f for f,r in defect.items() if not any(r[d]=='1' for d in D)])
row("ALL",list(defect))
# timing sub-buckets: the P0 signal
print("\n-- P0 bit-timing detail (28/29/34 vs standard 32) --")
for t in ['28','29','34']:
    row("timing=%s"%t,[f for f,r in defect.items() if r['bit_timing']==t])
