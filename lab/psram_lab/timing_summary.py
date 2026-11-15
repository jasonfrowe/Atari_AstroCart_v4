#!/usr/bin/env python3
"""Print Fmax / TNS / worst setup paths from a Gowin *_tr_content.html report."""
import html, re, sys
t = open(sys.argv[1]).read()
t = re.sub(r'<[^>]+>', ' ', t); t = html.unescape(t); t = re.sub(r'\s+', ' ', t)
for m in re.finditer(r'(\S+default_gen_clk) (\d+\.\d+)\(MHz\) (\d+\.\d+)\(MHz\) (\d+)', t):
    print(f"Fmax  {m.group(1)}: target {m.group(2)} MHz, achieved {m.group(3)} MHz")
for m in re.finditer(r'(\S+) (Setup|Hold) (-?\d+\.\d+) (\d+)', t[t.find('Total Negative Slack'):t.find('Timing Details')]):
    if m.group(3) != '0.000':
        print(f"TNS   {m.group(1)} {m.group(2)}: {m.group(3)} ns over {m.group(4)} endpoints")
i = t.find('Setup Paths Table'); seg = t[i:i + 3000]
print("worst setup paths:")
for m in list(re.finditer(r' \d+ (-?\d+\.\d+) (\S+) (\S+) \S+:\[\w\] \S+:\[\w\] ', seg))[:5]:
    print(f"  {m.group(1):>7} {m.group(2)} -> {m.group(3)}")
