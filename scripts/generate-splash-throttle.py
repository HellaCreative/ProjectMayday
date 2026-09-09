"""Generate the original synthetic splash sound; no third-party recording."""
import math, random, struct, wave
from pathlib import Path
random.seed(31)
rate=44100;duration=1.65;phase=0;filtered=0;values=[]
for i in range(int(rate*duration)):
 t=i/rate
 pulses=sum(math.exp(-((t-b)/.07)**2)*a for b,a in [(0,.5),(.44,.75),(.60,.8),(.76,.9)])
 surge=max(0,min(1,(t-.87)/.4))
 envelope=min(1,pulses+surge)*min(1,t/.008)*min(1,max(0,(duration-t)/.18))
 frequency=43+58*pulses+104*surge
 phase+=2*math.pi*frequency/rate
 filtered=.8*filtered+.2*random.uniform(-1,1)
 tone=math.sin(phase)+.42*math.sin(2*phase)+.22*math.sin(3*phase)+.12*math.sin(5*phase)
 values.append(math.tanh((tone*.62+filtered*.30)*envelope)*.72)
path=Path(__file__).resolve().parents[1]/'Dirt/Resources/SplashThrottle.wav'
with wave.open(str(path),'wb') as f:
 f.setparams((1,2,rate,0,'NONE','not compressed'))
 f.writeframes(b''.join(struct.pack('<h',int(v*32767)) for v in values))
print(f'{path.name}: {duration}s, peak {max(abs(v) for v in values):.3f}')
