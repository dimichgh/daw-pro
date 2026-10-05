import xml.etree.ElementTree as ET, glob, json
f = glob.glob('bwv846/lg-*.xml')[0]
r = ET.parse(f).getroot()
STEP = {'C':0,'D':2,'E':4,'F':5,'G':7,'A':9,'B':11}
parts = r.findall('part')
print("parts:", len(parts))
out = {}
for p in parts:
    for m in p.findall('measure'):
        num = int(m.get('number'))
        div = None
        for d in m.iter('divisions'):
            div = int(d.text)
        pos = 0
        cur = out.setdefault(num, [])
        for el in m:
            if el.tag == 'attributes':
                for d in el.iter('divisions'): DIV = int(d.text)
            if el.tag == 'note':
                dur = int(el.findtext('duration', '0'))
                if el.find('rest') is not None:
                    pos += dur; continue
                pch = el.find('pitch')
                if pch is None: pos += dur; continue
                mid = 12*(int(pch.findtext('octave'))+1) + STEP[pch.findtext('step')] + int(float(pch.findtext('alter') or 0))
                chord = el.find('chord') is not None
                st = pos - (cur[-1][2] if chord and cur else 0) if False else pos
                if chord and cur:
                    st = cur[-1][0]
                cur.append((st, mid, dur))
                if not chord: pos += dur
            if el.tag == 'backup':
                pos -= int(el.findtext('duration'))
            if el.tag == 'forward':
                pos += int(el.findtext('duration'))
DIVS = int(r.find('.//divisions').text)
print("divisions per quarter:", DIVS)
for m in range(1, 9):
    ns = sorted(out[m])
    print(f"m{m}: n={len(ns)} pitches={sorted(set(x[1] for x in ns))}")
    print("   ", [(round(s/DIVS,3), p, round(d/DIVS,3)) for s,p,d in ns])
json.dump({str(k): [[s/DIVS, p, d/DIVS] for s,p,d in sorted(v)] for k,v in out.items()}, open('bwv846.json','w'))
