const COLS="ABCDEFGHIJK";
const ROLE={start:"#3CCB6B",hand:"#2E96F0",finish:"#D64FD0"};
const MAKER={start:"#2FB04A",hand:"#2C6FE0",finish:"#E0393E"};
function parse(l){return{c:COLS.indexOf(l[0]),r:parseInt(l.slice(1),10)}}

function drawBoard(el,holds,o={}){
  const rows=o.rows||18,s=22,pad=24,w=pad+COLS.length*s+8,h=rows*s+pad+4;
  const at=(c,r)=>({x:pad+c*s+s/2,y:(rows-r)*s+s/2+4});
  let g=`<svg viewBox="0 0 ${w} ${h}" xmlns="http://www.w3.org/2000/svg"><defs><filter id="glow" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="3"/></filter></defs>`;
  for(let r=1;r<=rows;r++){const p=at(0,r);g+=`<text x="${pad-8}" y="${p.y+3.5}" fill="#8E8E96" font-size="9" font-weight="600" text-anchor="end" font-family="-apple-system,system-ui">${r}</text>`}
  for(let c=0;c<COLS.length;c++){const p=at(c,1);g+=`<text x="${p.x}" y="${h-1}" fill="#8E8E96" font-size="9" font-weight="600" text-anchor="middle" font-family="-apple-system,system-ui">${COLS[c]}</text>`}
  for(let r=1;r<=rows;r++)for(let c=0;c<COLS.length;c++){const p=at(c,r);const big=((c*7+r*3)%5)<2;g+=`<circle cx="${p.x}" cy="${p.y}" r="${big?5.2:3.6}" fill="${big?'#45454C':'#36363C'}"/>`}
  for(const hd of holds){const{c,r}=parse(hd.at),p=at(c,r),col=ROLE[hd.role];
    g+=`<circle cx="${p.x}" cy="${p.y}" r="9" fill="${col}" opacity=".35" filter="url(#glow)"/>`;
    g+=`<circle cx="${p.x}" cy="${p.y}" r="8" fill="none" stroke="${col}" stroke-width="2.6" ${hd.unsure?'stroke-dasharray="3.2 2.6"':''}/>`;
    if(hd.unsure)g+=`<circle cx="${p.x+7}" cy="${p.y-7}" r="4.6" fill="#DDB13A"/><text x="${p.x+7}" y="${p.y-4.6}" fill="#1A1A1A" font-size="7" font-weight="800" text-anchor="middle" font-family="-apple-system,system-ui">?</text>`;
    if(hd.focus)g+=`<circle cx="${p.x}" cy="${p.y}" r="12" fill="none" stroke="#fff" stroke-width="1.4" opacity=".9"/>`;
  }
  el.innerHTML=g+"</svg>";
}

function drawShot(el,kind,holds=[]){
  const W=180,H=390;let g=`<svg viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg"><rect width="${W}" height="${H}" fill="#F2F2F4"/>`;
  g+=`<rect x="0" y="0" width="${W}" height="54" fill="#FFFFFF"/><rect x="14" y="20" width="70" height="8" rx="4" fill="#C9C9CF"/><rect x="14" y="34" width="44" height="6" rx="3" fill="#DEDEE3"/><rect x="${W-44}" y="22" width="30" height="12" rx="6" fill="#DEDEE3"/>`;
  if(kind==="photo"){
    g+=`<rect x="0" y="54" width="${W}" height="${H-54}" fill="#B9A58C"/><circle cx="60" cy="150" r="40" fill="#9C8B72"/><circle cx="130" cy="240" r="58" fill="#A8977C"/><path d="M0 300 Q60 260 180 310 V390 H0Z" fill="#7F6F5A"/><circle cx="110" cy="120" r="9" fill="#E0393E"/><circle cx="50" cy="270" r="7" fill="#2FB04A"/>`;
    return el.innerHTML=g+"</svg>";
  }
  const rows=kind==="mini"?12:18,s=14,x0=13,y0=66,bh=rows*s+10;
  const visible=kind==="cropped"?11:rows;
  g+=`<rect x="6" y="${y0-6}" width="${W-12}" height="${bh}" rx="6" fill="#2B2B30"/>`;
  for(let r=1;r<=rows;r++)for(let c=0;c<11;c++){g+=`<circle cx="${x0+c*s+s/2}" cy="${y0+(rows-r)*s+s/2}" r="${((c*7+r*3)%5)<2?3.4:2.4}" fill="#55555C"/>`}
  for(const hd of holds){const{c,r}=parse(hd.at);if(r>rows)continue;g+=`<circle cx="${x0+c*s+s/2}" cy="${y0+(rows-r)*s+s/2}" r="6.4" fill="none" stroke="${MAKER[hd.role]}" stroke-width="2.2"/>`}
  g+=`<rect x="14" y="${y0+bh+10}" width="90" height="8" rx="4" fill="#C9C9CF"/><rect x="14" y="${y0+bh+24}" width="60" height="6" rx="3" fill="#DEDEE3"/>`;
  if(kind==="cropped"){const cut=y0+(rows-visible)*s-6;g=g.replace('<rect width="180"','<rect width="180"');g+=`<rect x="0" y="0" width="${W}" height="${cut}" fill="#0B0C12" opacity=".82"/><line x1="0" y1="${cut}" x2="${W}" y2="${cut}" stroke="#E5743A" stroke-width="2" stroke-dasharray="5 4"/>`}
  el.innerHTML=g+"</svg>";
}

const SIDE=`<div class="brand">Sendmeter</div>
<a><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>Today</a>
<a><img src="../../../native/SendmeterNative/Resources/Assets.xcassets/WorkoutMascotTab.imageset/workout-r16-exact-24.svg" alt="">Session</a>
<a class="on"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="5" cy="5" r="2"/><circle cx="12" cy="5" r="2"/><circle cx="19" cy="5" r="2"/><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/><circle cx="5" cy="19" r="2"/><circle cx="12" cy="19" r="2"/><circle cx="19" cy="19" r="2"/></svg>Board</a>
<a><img src="../../../native/SendmeterNative/Resources/Assets.xcassets/ForceMascotTab.imageset/r11-force-control-24.svg" alt="">Force</a>
<a><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 4h11a2 2 0 0 1 2 2v14H7a2 2 0 0 1-2-2z"/><path d="M5 18a2 2 0 0 1 2-2h11"/></svg>Log</a>`;
document.querySelectorAll(".side").forEach(e=>e.innerHTML=SIDE);
const STATUS=`<span>9:41</span><span style="letter-spacing:2px">▂▄▆ ◉ ▭</span>`;
document.querySelectorAll(".status").forEach(e=>e.innerHTML=STATUS);
const ROUTE=[{at:"F5",role:"start"},{at:"D8",role:"hand"},{at:"G10",role:"hand",unsure:true},{at:"C12",role:"hand"},{at:"H13",role:"hand"},{at:"E15",role:"hand"},{at:"F18",role:"finish"}];
