#!/usr/bin/env python3
from pathlib import Path
import argparse
import difflib
import sys

ap = argparse.ArgumentParser()
ap.add_argument('--src-root', required=True)
ap.add_argument('--audit-dir', required=True)
a = ap.parse_args()
src = Path(a.src_root)
audit = Path(a.audit_dir)
audit.mkdir(parents=True, exist_ok=True)

def fail(msg):
    print(f'ERROR: audio source transform: {msg}', file=sys.stderr)
    raise SystemExit(1)

def write_diff(name, rel, old, new):
    d = ''.join(difflib.unified_diff(
        old.splitlines(True), new.splitlines(True),
        fromfile='a/' + rel, tofile='b/' + rel, n=3))
    if not d:
        fail(f'{name}: generated diff is empty')
    out = audit / name
    out.write_text(d)
    print(f'>> generated audit patch: {out}')

# sun4i-i2s: widen capture only.
rel = 'sound/soc/sunxi/sun4i-i2s.c'
p = src / rel
old = p.read_text()
new = old
start = new.find('\t.capture = {')
if start < 0:
    fail('sun4i-i2s capture block not found')
end = new.find('\n\t},', start)
if end < 0:
    fail('sun4i-i2s capture block end not found')
block = new[start:end + 4]
needle = '\t\t.rates = SNDRV_PCM_RATE_8000_192000,'
count = block.count(needle)
if count != 1:
    fail(f'sun4i-i2s capture rate mask count is {count}, expected 1')
block2 = block.replace(
    needle,
    '\t\t.rates = SNDRV_PCM_RATE_8000_192000 | SNDRV_PCM_RATE_24000,',
    1)
new = new[:start] + block2 + new[end + 4:]
if new.count('SNDRV_PCM_RATE_8000_192000 | SNDRV_PCM_RATE_24000') != 1:
    fail('sun4i-i2s widened mask count is not exactly 1')
p.write_text(new)
write_diff('0001-sun4i-i2s-capture-24khz.patch', rel, old, new)

# simple-card: fixed capture-only machine policy.
rel = 'sound/soc/generic/simple-card.c'
p = src / rel
old = p.read_text()
new = old
inc = '#include <linux/string.h>\n'
if new.count(inc) != 1:
    fail('simple-card linux/string include anchor count is not 1')
if '#include <sound/pcm.h>' in new:
    fail('simple-card already contains sound/pcm.h')
new = new.replace(inc, inc + '#include <sound/pcm.h>\n', 1)
anchor = 'static const struct snd_soc_ops simple_ops = {\n'
if new.count(anchor) != 1:
    fail('simple-card ops anchor count is not 1')
func = '''static const unsigned int mkclock_capture_rates[] = {
\t24000,
};

static const struct snd_pcm_hw_constraint_list mkclock_capture_rate_constraint = {
\t.count = ARRAY_SIZE(mkclock_capture_rates),
\t.list = mkclock_capture_rates,
\t.mask = 0,
};

static int simple_mkclock_startup(struct snd_pcm_substream *substream)
{
\tstruct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
\tu32 capture_rate;
\tint ret;

\tret = simple_util_startup(substream);
\tif (ret)
\t\treturn ret;

\tif (substream->stream != SNDRV_PCM_STREAM_CAPTURE)
\t\treturn 0;

\tif (of_property_read_u32(rtd->card->dev->of_node,
\t\t\t\t "icubedev,capture-rate-hz", &capture_rate))
\t\treturn 0;

\tif (capture_rate != mkclock_capture_rates[0]) {
\t\tsimple_util_shutdown(substream);
\t\treturn -EINVAL;
\t}

\tret = snd_pcm_hw_constraint_list(substream->runtime, 0,
\t\t\t\t\t SNDRV_PCM_HW_PARAM_RATE,
\t\t\t\t\t &mkclock_capture_rate_constraint);
\tif (ret < 0)
\t\tsimple_util_shutdown(substream);

\treturn ret;
}

'''
new = new.replace(anchor, func + anchor, 1)
startup_candidates = [
    '\t.startup\t= simple_util_startup,',
    '\t.startup        = simple_util_startup,',
]
startup = next((x for x in startup_candidates if new.count(x) == 1), None)
if startup is None:
    fail('simple-card startup assignment count is not exactly 1')
new = new.replace(startup, startup.replace('simple_util_startup', 'simple_mkclock_startup'), 1)
for token in [
    'snd_pcm_hw_constraint_list', 'icubedev,capture-rate-hz',
    'SNDRV_PCM_STREAM_CAPTURE', 'simple_mkclock_startup',
]:
    if token not in new:
        fail(f'simple-card post-transform token missing: {token}')
p.write_text(new)
write_diff('0002-simple-card-fixed-capture-rate.patch', rel, old, new)
