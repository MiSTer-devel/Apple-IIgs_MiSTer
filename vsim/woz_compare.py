#!/usr/bin/env python3
"""Compare a post-fix results.csv against the baseline.
Usage: woz_compare.py <new_results.csv> [baseline_results.csv]"""
import csv,sys,collections
new=sys.argv[1]; old=sys.argv[2] if len(sys.argv)>2 else 'woz_baseline/results.csv'
def load(p):
    d={}
    for r in csv.reader(open(p)):
        if r and r[0]!='status': d[r[5].strip('"').replace('woztest/','')]=(r[0],r[2])
    return d
A,B=load(old),load(new)
common=[f for f in B if f in A]
RANK={'BOOTED':3,'TEXT_ONLY':2,'BLANK':1,'TIMEOUT':0,'CRASH':0}
fixed=[f for f in common if RANK[B[f][0]]>RANK[A[f][0]]]
broke=[f for f in common if RANK[B[f][0]]<RANK[A[f][0]]]
same=[f for f in common if B[f][0]==A[f][0]]
hashdiff=[f for f in same if B[f][1]!=A[f][1]]
print("compared %d disks\n"%len(common))
print("  IMPROVED : %d"%len(fixed))
print("  REGRESSED: %d"%len(broke))
print("  unchanged: %d  (of which %d changed screenshot hash)"%(len(same),len(hashdiff)))
if fixed:
    print("\n-- improved --")
    for f in sorted(fixed): print("   %-58s %s -> %s"%(f[:58],A[f][0],B[f][0]))
if broke:
    print("\n-- REGRESSED --")
    for f in sorted(broke): print("   %-58s %s -> %s"%(f[:58],A[f][0],B[f][0]))
