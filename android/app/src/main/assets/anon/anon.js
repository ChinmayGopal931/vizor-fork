var Kt=Object.defineProperty;var p=(t,e,r)=>()=>{if(r)throw r[0];try{return t&&(e=t(t=0)),e}catch(n){throw r=[n],n}};var Vt=(t,e)=>{for(var r in e)Kt(t,r,{get:e[r],enumerable:!0})};function C(t){let e=()=>new Error(`address: malformed (expected <ip>:<port>:<certhash> or [ipv6]:<port>:<certhash>): ${t}`),r,n;if(t.startsWith("[")){let c=t.indexOf("]");if(c<0||t[c+1]!==":")throw e();r=t.slice(1,c),n=t.slice(c+2)}else{let c=t.indexOf(":");if(c<0)throw e();r=t.slice(0,c),n=t.slice(c+1)}let o=n.indexOf(":");if(o<0)throw e();let s=n.slice(0,o),a=n.slice(o+1);if(!/^\d+$/.test(s))throw e();let i=Number(s);if(i<1||i>65535)throw new Error("address: port out of range");if(!r||!a)throw e();return{ip:r,port:i,certhash:a}}function we(t){return`${t.ip.includes(":")?`[${t.ip}]`:t.ip}:${t.port}:${t.certhash}`}var tt=p(()=>{});function U(t){if(!t.startsWith("u"))throw new Error(`certhash: expected multibase prefix 'u', got '${t[0]??""}'`);let e=wr(t.slice(1));if(e.length!==34)throw new Error(`certhash: expected 34 bytes, got ${e.length}`);if(e[0]!==18||e[1]!==32)throw new Error(`certhash: not a sha2-256 multihash (prefix ${e[0].toString(16)} ${e[1].toString(16)})`);return e.slice(2)}function rt(t){return Array.from(t,e=>e.toString(16).padStart(2,"0").toUpperCase()).join(":")}function wr(t){let e=(4-t.length%4)%4,r=t.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat(e),n=atob(r),o=new Uint8Array(n.length);for(let s=0;s<n.length;s++)o[s]=n.charCodeAt(s);return o}var ge=p(()=>{});function m(t){let e=new Error(t.message??`kps: stream ${t.code??"reset"}`);return e.code=t.code,e}function be(t){if(t!=null)return typeof t=="object"&&("code"in t||"message"in t)?t:{message:String(t?.message??t)}}var ye=p(()=>{});var Ae=p(()=>{tt();ge()});function B(t){return t?nt[t]??0:0}function F(t){return t===0?void 0:gr[t]??"internal-error"}function ot(t){let e=new Uint8Array(1+t.length);return e[0]=0,e.set(t,1),e}function st(){return new Uint8Array([1])}function K(t,e){let r=new Uint8Array(5);return r[0]=t,new DataView(r.buffer).setUint32(1,e>>>0,!1),r}function it(t){let e=new Uint8Array(9);return e[0]=4,new DataView(e.buffer).setBigUint64(1,t,!1),e}function at(t){if(t.length===0)throw new f("empty data-channel message");if(t.length>16384)throw new f(`frame exceeds 16384 bytes (${t.length})`);let e=t[0],r=t.subarray(1),n=()=>new DataView(r.buffer,r.byteOffset,r.byteLength);switch(e){case 0:if(r.length===0)throw new f("empty DATA frame");return{type:"data",payload:r};case 1:if(r.length!==0)throw new f("FIN with payload");return{type:"fin"};case 2:if(r.length!==4)throw new f("RESET payload must be 4 bytes");return{type:"reset",code:n().getUint32(0,!1)};case 3:if(r.length!==4)throw new f("STOP_SENDING payload must be 4 bytes");return{type:"stop-sending",code:n().getUint32(0,!1)};case 4:{if(r.length!==8)throw new f("MAX_STREAM_DATA payload must be 8 bytes");let o=n().getBigUint64(0,!1);if(o>A)throw new f("MAX_STREAM_DATA above MAX_OFFSET");return{type:"max-stream-data",value:o}}default:throw new f(`unknown frame type 0x${e.toString(16)}`)}}var A,f,nt,gr,P=p(()=>{A=(1n<<62n)-1n,f=class extends Error{},nt={cancelled:1,closed:2,reset:3,timeout:4,"network-error":5,"protocol-error":6,unsupported:7,"too-large":8,"queue-full":9,"permission-denied":10,"internal-error":11},gr=Object.fromEntries(Object.entries(nt).map(([t,e])=>[e,t]))});function z(t){let e=new Uint8Array(5);return e[0]=ct,new DataView(e.buffer).setUint32(1,B(t),!1),e}function ft(t,e=V){let r=new Uint8Array(26),n=new DataView(r.buffer);return r[0]=lt,r[1]=e,n.setBigUint64(2,t.initialMaxStreamData,!1),n.setBigUint64(10,t.initialMaxData,!1),n.setBigUint64(18,t.initialMaxStreams,!1),r}function ut(t){let e=new Uint8Array(9);return e[0]=dt,new DataView(e.buffer).setBigUint64(1,t,!1),e}function pt(t){let e=new Uint8Array(9);return e[0]=ht,new DataView(e.buffer).setBigUint64(1,t,!1),e}function mt(t){if(t.length===0)throw new f("empty control message");let e=t[0],r=new DataView(t.buffer,t.byteOffset,t.byteLength);switch(e){case ct:if(t.length!==5)throw new f("CONNECTION_CLOSE must be 5 bytes");return{t:"close",code:r.getUint32(1,!1)};case lt:{if(t.length!==26)throw new f("HELLO must be 26 bytes");let n={initialMaxStreamData:r.getBigUint64(2,!1),initialMaxData:r.getBigUint64(10,!1),initialMaxStreams:r.getBigUint64(18,!1)};for(let o of Object.values(n))if(o>A)throw new f("HELLO credit above MAX_OFFSET");return{t:"hello",version:t[1],limits:n}}case dt:{if(t.length!==9)throw new f("MAX_DATA must be 9 bytes");let n=r.getBigUint64(1,!1);if(n>A)throw new f("MAX_DATA above MAX_OFFSET");return{t:"max-data",value:n}}case ht:{if(t.length!==9)throw new f("MAX_STREAMS must be 9 bytes");let n=r.getBigUint64(1,!1);if(n>A)throw new f("MAX_STREAMS above MAX_OFFSET");return{t:"max-streams",value:n}}default:throw new f(`unknown control message type 0x${e.toString(16)}`)}}var ct,lt,dt,ht,V,wt=p(()=>{P();ct=0,lt=1,dt=2,ht=3,V=1});function gt(t){return{initialMaxStreamData:t?.initialMaxStreamData??br,initialMaxData:t?.initialMaxData??yr,initialMaxStreams:t?.initialMaxStreams??Ar}}function Ee(t){return t>A?A:t}var br,yr,Ar,xe,G,Se,bt=p(()=>{P();br=1n<<20n,yr=8n<<20n,Ar=100n;xe=class{#e=[];wake(){let e=this.#e;this.#e=[];for(let r of e)r()}wait(e){return new Promise((r,n)=>{if(e){let o=()=>n(new Error("kps: aborted"));e.addEventListener("abort",o,{once:!0}),this.#e.push(()=>{e.removeEventListener("abort",o),r()})}else this.#e.push(r)})}},G=class{local;#e=0n;#t=0n;#r=0n;#a=0n;#o=0n;#s=0n;#i=0n;#n;#d=0n;#h=0n;#p=0n;#m=0n;#u=0n;#l;#f=new xe;#c=null;#g;constructor(e,r){this.local=e,this.#n=e.initialMaxData,this.#l=e.initialMaxStreams,this.#g=r}onPeerHello(e){this.#e=e.initialMaxStreamData,this.#t=e.initialMaxData,this.#r=e.initialMaxStreams,this.#f.wake()}onPeerMaxData(e){e>this.#t&&(this.#t=e,this.#f.wake())}onPeerMaxStreams(e){e>this.#r&&(this.#r=e,this.#f.wake())}fail(e){this.#c||(this.#c=e,this.#f.wake())}wake(){this.#f.wake()}get failed(){return this.#c}get peerInitialMaxStreamData(){return this.#e}newStream(e){return new Se(this,this.local.initialMaxStreamData,e)}async reserveData(e,r,n){for(;;){if(this.#c)throw this.#c;let o=e.sendFailed;if(o)throw o;if(n?.aborted)throw new Error("kps: aborted");let s=e.peerMaxStreamData-e.sendSent-e.sendReserved,a=this.#t-this.#a-this.#o,i=s<a?s:a;if(i>r&&(i=r),i>=1n)return e.sendReserved+=i,this.#o+=i,i;await this.#f.wait(n)}}commitData(e,r){e.sendReserved-=r,e.sendSent+=r,this.#o-=r,this.#a+=r}releaseData(e,r){e.sendReserved-=r,this.#o-=r,this.#f.wake()}async reserveStreamSlot(e){for(;;){if(this.#c)throw this.#c;if(e?.aborted)throw new Error("kps: aborted");if(this.#s+this.#i<this.#r){this.#i+=1n;return}await this.#f.wait(e)}}commitStreamSlot(){this.#i-=1n,this.#s+=1n}releaseStreamSlot(){this.#i-=1n,this.#f.wake()}connDataReceived(e){if(this.#d+e>this.#n)throw new f("peer exceeded MAX_DATA");this.#d+=e}connDataConsumed(e){this.#h+=e;let r=this.local.initialMaxData;this.#h-this.#p>=r/2n&&(this.#p=this.#h,this.#n=Ee(this.#h+r),this.#g.sendMaxData(this.#n))}peerStreamOpened(){if(this.#m>=this.#l)throw new f("peer exceeded MAX_STREAMS");this.#m+=1n}peerStreamRetired(){this.#u+=1n,this.#l=Ee(this.local.initialMaxStreams+this.#u),this.#g.sendMaxStreams(this.#l)}},Se=class{sendSent=0n;sendReserved=0n;#e=0n;#t=null;#r;#a=0n;#o=0n;#s=0n;#i=!1;#n;#d;constructor(e,r,n){this.#n=e,this.#r=r,this.#d=n}get peerMaxStreamData(){let e=this.#n.peerInitialMaxStreamData;return this.#e>e?this.#e:e}async reserve(e,r){return Number(await this.#n.reserveData(this,BigInt(e),r))}commit(e){this.#n.commitData(this,BigInt(e))}release(e){this.#n.releaseData(this,BigInt(e))}failSend(e){this.#t||(this.#t=e,this.#n.wake())}get sendFailed(){return this.#t}onPeerMaxStreamData(e){e>this.#e&&(this.#e=e,this.#n.wake())}onDataReceived(e){let r=BigInt(e);if(this.#a+r>this.#r)throw new f("peer exceeded MAX_STREAM_DATA");this.#n.connDataReceived(r),this.#a+=r}onConsumed(e){let r=BigInt(e);this.#o+=r;let n=this.#n.local.initialMaxStreamData;!this.#i&&this.#o-this.#s>=n/2n&&(this.#s=this.#o,this.#r=Ee(this.#o+n),this.#d(this.#r)),this.#n.connDataConsumed(r)}markCancelled(){this.#i=!0}}});var At,Y,J,Et=p(()=>{P();ye();At=1<<20,Y=class{#e=[];wake(){let e=this.#e;this.#e=[];for(let r of e)r()}wait(){return new Promise(e=>this.#e.push(e))}},J=class{readable;writable;closed;opened;#e;#t;#r;#a=[];#o=!1;#s=null;#i=null;#n=null;#d=!1;#h=null;#p=!1;#m=!1;#u=new Y;#l=new Y;#f;#c=!1;#g;#w;#E=!1;constructor(e,r,n){this.#e=e,this.#r=n,this.#t=r.newStream(o=>{this.#e.isOpen()&&this.#e.send(it(o))}),this.closed=new Promise(o=>{this.#f=o}),this.opened=new Promise((o,s)=>{this.#g=o,this.#w=s}),this.opened.catch(()=>{}),e.setBufferedAmountLowThreshold(At),e.onBufferedAmountLow(()=>this.#l.wake()),e.onOpen(()=>this.#v(null)),e.isOpen()&&this.#v(null),e.onMessage(o=>this.#L(o)),e.onClose(()=>this.#_()),e.onError(o=>{this.#y({ok:!1,reason:{code:"network-error",message:o}}),this.#v(new Error(`kps: stream failed: ${o}`)),this.#u.wake(),this.#l.wake()}),this.readable=new ReadableStream({pull:async o=>{for(;;){if(this.#d){o.error(m(this.#h??{code:"cancelled"}));return}let s=this.#a.shift();if(s){o.enqueue(s),this.#t.onConsumed(s.length),this.#b();return}if(this.#s){o.error(m(this.#s));return}if(this.#o){o.close();return}if(this.#p){o.error(m({code:"network-error",message:"kps: stream closed"}));return}await this.#u.wait()}},cancel:o=>{this.cancelRead(be(o)??{code:"cancelled"})}},{highWaterMark:0}),this.writable=new WritableStream({write:o=>this.#A(o),close:()=>this.closeWrite(),abort:o=>this.resetWrite(be(o)??{code:"reset"})})}#L(e){let r;try{r=at(e)}catch(n){this.#r.fatal({code:"protocol-error",message:n.message});return}switch(r.type){case"data":{if(this.#o||this.#s){this.#r.fatal({code:"protocol-error",message:"DATA after terminal frame"});return}try{this.#t.onDataReceived(r.payload.length)}catch(n){this.#r.fatal({code:"protocol-error",message:n.message});return}if(this.#d){this.#t.onConsumed(r.payload.length);return}this.#a.push(r.payload.slice()),this.#u.wake();return}case"fin":{if(this.#o||this.#s){this.#r.fatal({code:"protocol-error",message:"second terminal frame"});return}this.#o=!0,this.#u.wake(),this.#b();return}case"reset":{if(this.#o||this.#s){this.#r.fatal({code:"protocol-error",message:"second terminal frame"});return}this.#s={code:F(r.code)??"reset"},this.#S(),this.#u.wake(),this.#b();return}case"stop-sending":{if(this.#i)return;this.#i={code:F(r.code)??"cancelled"},this.#t.failSend(m(this.#i)),this.#n||(this.#n="reset",this.#e.isOpen()&&this.#e.send(K(2,r.code)),this.#b());return}case"max-stream-data":this.#t.onPeerMaxStreamData(r.value);return}}#_(){this.#p=!0,!(this.#n!==null&&(this.#o||this.#s!==null))&&!this.#r.isTeardown()&&this.#r.fatal({code:"protocol-error",message:"data channel closed mid-stream"}),this.#t.failSend(m({code:"network-error",message:"kps: stream closed"})),this.#v(new Error("kps: stream closed before opening")),this.#y({ok:!this.#s,reason:this.#s??void 0}),this.#u.wake(),this.#l.wake(),this.#b()}async#A(e){let r=0;for(;r<e.length;){this.#x();let n=Math.min(e.length-r,16383),o=await this.#t.reserve(n),s=e.subarray(r,r+o);try{await this.#k(),this.#x(),this.#e.send(ot(s))}catch(a){throw this.#t.release(o),a}this.#t.commit(o),r+=o}}#x(){if(this.#i)throw m(this.#i);if(this.#n)throw m({code:"closed",message:"kps: write half closed"});if(this.#p||!this.#e.isOpen())throw new Error("kps: stream is closed")}async#k(){for(;this.#e.isOpen()&&this.#e.bufferedAmount()>=At;)await this.#l.wait()}async closeWrite(){this.#n||(this.#n="fin",this.#t.failSend(m({code:"closed",message:"kps: write half closed"})),this.#e.isOpen()&&this.#e.send(st()),this.#b())}async cancelRead(e){this.#d||(this.#d=!0,this.#h=e??{code:"cancelled"},this.#t.markCancelled(),this.#S(),!this.#o&&!this.#s&&this.#e.isOpen()&&this.#e.send(K(3,B(e?.code??"cancelled"))),this.#u.wake(),this.#b())}async resetWrite(e){this.#n||(this.#n="reset",this.#t.failSend(m(e??{code:"reset"})),this.#e.isOpen()&&this.#e.send(K(2,B(e?.code??"reset"))),this.#b())}async close(e){try{await this.closeWrite()}catch{}try{await this.cancelRead(e??{code:"closed"})}catch{}}destroy(e){this.#S(),this.#d=!0,this.#h=e??{code:"closed",message:"kps: connection closed"},this.#t.failSend(m(e??{code:"closed",message:"kps: connection closed"})),this.#v(new Error("kps: connection closed")),this.#y(e?{ok:!1,reason:e}:{ok:!0}),this.#u.wake(),this.#l.wake()}#S(){if(this.#a.length===0)return;let e=0;for(let r of this.#a)e+=r.length;this.#a=[],this.#t.onConsumed(e)}#b(){if(!(!(this.#n!==null&&(this.#o||this.#s!==null))||!(this.#a.length===0))){if(!this.#p){this.#e.close();return}this.#m||(this.#m=!0,this.#r.retired())}}#y(e){this.#c||(this.#c=!0,this.#f(e))}#v(e){this.#E||(this.#E=!0,e?this.#w(e):this.#g())}}});function _r(t,e,r){return e?e.aborted?Promise.reject(new Error(r)):new Promise((n,o)=>{let s=()=>o(new Error(r));e.addEventListener("abort",s,{once:!0}),t.then(a=>{e.removeEventListener("abort",s),n(a)},a=>{e.removeEventListener("abort",s),o(a)})}):t}var Q,Z,ve,ee,_e,Sr,vr,H,xt=p(()=>{P();wt();bt();Et();ye();Q=1200,Z="_kps_control",ve=0,ee="_kps_datagrams",_e=1,Sr=15e3,vr=256;H=class{closed;established;flow;#e;#t="connecting";#r=!1;#a=!1;#o=null;#s=!1;#i;#n;#d;#h=0;#p=new Set;#m=[];#u=[];#l=[];#f=[];#c=[];#g;#w=!1;constructor(e){this.#e=e,this.closed=new Promise(r=>{this.#g=r}),this.established=new Promise((r,n)=>{this.#i=r,this.#n=n}),this.established.catch(()=>{}),this.flow=new G(gt(e.limits),{sendMaxData:r=>this.#A(ut(r)),sendMaxStreams:r=>this.#A(pt(r))}),e.control.onOpen(()=>this.#E()),e.control.onMessage(r=>this.#L(r)),e.control.onClose(()=>this.#x("control")),e.control.onError(()=>this.#x("control")),e.control.isOpen()&&this.#E(),e.datagram.onMessage(r=>this.#b(r)),e.datagram.onClose(()=>this.#x("datagram")),this.#d=setTimeout(()=>this.fatal({code:"timeout",message:"kps: HELLO timeout"}),e.helloTimeoutMs??Sr),this.#d.unref?.()}get state(){return this.#t}#E(){this.#a||this.#w||(this.#a=!0,this.#A(ft(this.flow.local)),this.#_())}#L(e){let r;try{r=mt(e)}catch(n){this.fatal({code:"protocol-error",message:n.message});return}switch(r.t){case"hello":{if(this.#o){this.fatal({code:"protocol-error",message:"duplicate HELLO"});return}if(r.version!==V){this.#A(z("unsupported")),this.#y({ok:!1,reason:{code:"unsupported",message:`kps: peer wire version ${r.version} (want ${V})`}});return}this.#o=r.limits,this.flow.onPeerHello(r.limits),this.#_();return}case"close":{let n=r.code===0?void 0:{code:F(r.code)??"internal-error"};this.#y({ok:r.code===0,reason:n});return}case"max-data":if(!this.#o){this.fatal({code:"protocol-error",message:"control message before HELLO"});return}this.flow.onPeerMaxData(r.value);return;case"max-streams":if(!this.#o){this.fatal({code:"protocol-error",message:"control message before HELLO"});return}this.flow.onPeerMaxStreams(r.value);return}}#_(){if(this.#s||this.#w||!this.#a||!this.#o)return;this.#s=!0,this.#t="open",clearTimeout(this.#d),this.#i();let e=this.#m;this.#m=[];for(let r of e)this.#S(r)}#A(e){try{this.#e.control.isOpen()&&this.#e.control.send(e)}catch{}}#x(e){this.#r||this.#w||this.fatal({code:"protocol-error",message:`kps: reserved ${e} channel lost`})}handleIncomingChannel(e){try{this.flow.peerStreamOpened()}catch(n){this.fatal({code:"protocol-error",message:n.message});return}let r=this.#k(e,!0);this.#s?this.#S(r):this.#m.push(r)}#k(e,r){let n=new J(e,this.flow,{fatal:o=>this.fatal(o),retired:()=>{this.#p.delete(n),r&&this.flow.peerStreamRetired()},isTeardown:()=>this.#r});return this.#p.add(n),n}#S(e){let r=this.#l.shift();r?r.resolve(e):this.#u.push(e)}async openStream(e={}){if(e.signal?.aborted)throw new Error("kps: openStream aborted");if(this.#t!=="open")throw new Error(`kps: connection is ${this.#t}`);await this.flow.reserveStreamSlot(e.signal);let r;try{r=this.#e.openChannel(`kps-${++this.#h}`)}catch(o){throw this.flow.releaseStreamSlot(),o}this.flow.commitStreamSlot();let n=this.#k(r,!1);try{await _r(n.opened,e.signal,"kps: openStream aborted")}catch(o){throw n.opened.then(()=>{n.resetWrite({code:"cancelled"}),n.cancelRead({code:"cancelled"})}).catch(()=>{}),o}return n}acceptStream(e={}){let r=this.#u.shift();if(r)return Promise.resolve(r);if(e.signal?.aborted)return Promise.reject(new Error("kps: acceptStream aborted"));if(this.#t==="closed")return Promise.reject(new Error("kps: connection is closed"));let n=e.signal;return new Promise((o,s)=>{let a={resolve:c=>{n?.removeEventListener("abort",i),o(c)},reject:c=>{n?.removeEventListener("abort",i),s(c)}},i=()=>{let c=this.#l.indexOf(a);c>=0&&this.#l.splice(c,1),s(new Error("kps: acceptStream aborted"))};this.#l.push(a),n?.addEventListener("abort",i,{once:!0})})}#b(e){let r=this.#c.shift();if(r){r.resolve(e);return}this.#f.push(e),this.#f.length>vr&&this.#f.shift()}async sendDatagram(e,r){if(r?.signal?.aborted)throw new Error("kps: sendDatagram aborted");if(e.length>Q){let n=new Error(`kps: datagram exceeds limit (max ${Q} bytes)`);throw Object.assign(n,{code:"too-large",maxDatagramPayloadSize:Q}),n}if(!this.#e.datagram.isOpen())throw new Error("kps: datagram channel not open");this.#e.datagram.send(e)}receiveDatagram(e){let r=this.#f.shift();if(r)return Promise.resolve(r);if(this.#t==="closed")return Promise.reject(new Error("kps: connection closed"));if(e?.signal?.aborted)return Promise.reject(new Error("kps: receiveDatagram aborted"));let n=e?.signal;return new Promise((o,s)=>{let a={resolve:c=>{n?.removeEventListener("abort",i),o(c)},reject:c=>{n?.removeEventListener("abort",i),s(c)}},i=()=>{let c=this.#c.indexOf(a);c>=0&&this.#c.splice(c,1),s(new Error("kps: receiveDatagram aborted"))};this.#c.push(a),n?.addEventListener("abort",i,{once:!0})})}close(e){this.#w||(this.#r=!0,this.#A(z(e?.code)),this.#y({ok:!0,reason:e}))}fatal(e){this.#w||(this.#r=!0,this.#A(z(e.code??"protocol-error")),this.#y({ok:!1,reason:e}))}onTransportFailed(e="peer connection failed"){this.#y({ok:!1,reason:{code:"network-error",message:e}})}onTransportClosed(){this.#y({ok:this.#t!=="connecting"})}#y(e){if(this.#w)return;this.#w=!0,this.#r=!0,this.#t="closed",clearTimeout(this.#d);let r=e.reason?m(e.reason):new Error("kps: connection closed");this.#s||this.#n(r),this.flow.fail(r);for(let n of[...this.#p,...this.#m])n.destroy(e.reason);this.#p.clear(),this.#m=[];for(let n of this.#l)n.reject(new Error("kps: connection closed"));this.#l=[];for(let n of this.#c)n.reject(new Error("kps: connection closed"));this.#c=[];try{this.#e.closeTransport()}catch{}this.#g(e)}}});function ke(){let t=new Uint8Array(8);return crypto.getRandomValues(t),Array.from(t,e=>e.toString(16).padStart(2,"0")).join("")}async function Le(t,e){let r=await crypto.subtle.importKey("raw",St(t),{name:"HMAC",hash:"SHA-256"},!1,["sign"]),n=new TextEncoder().encode("kps-ice-pwd-v1:"+e),o=new Uint8Array(await crypto.subtle.sign("HMAC",r,St(n))),s="";for(let a of o)s+=String.fromCharCode(a);return btoa(s).replace(/=+$/,"")}function St(t){return t.buffer.slice(t.byteOffset,t.byteOffset+t.byteLength)}function Me(t,e,r){return t.split(/\r\n|\n/).map(o=>o.startsWith("a=ice-ufrag:")?`a=ice-ufrag:${e}`:o.startsWith("a=ice-pwd:")?`a=ice-pwd:${r}`:o).join(`\r
`)}function Te(t,e,r){let n=rt(U(t.certhash)),o=t.ip.includes(":"),s=o?"IP6":"IP4";return["v=0",`o=- 0 0 IN ${s} ${o?"::":"0.0.0.0"}`,"s=-","t=0 0","a=ice-lite",`m=application ${t.port} UDP/DTLS/SCTP webrtc-datachannel`,`c=IN ${s} ${t.ip}`,"a=mid:0",`a=ice-ufrag:${e}`,`a=ice-pwd:${r}`,`a=fingerprint:sha-256 ${n}`,"a=setup:passive","a=sctp-port:5000","a=max-message-size:1048576",`a=candidate:1 1 UDP 1 ${t.ip} ${t.port} typ host`].join(`\r
`)+`\r
`}var vt=p(()=>{ge()});var _t=p(()=>{xt();vt()});function Lr(t){return t.buffer.slice(t.byteOffset,t.byteOffset+t.byteLength)}function kt(t){let e=t.reason;return new Error(e?.name==="TimeoutError"?"kps: dial timed out":"kps: dial aborted")}function _(t,e){return Ie.dial(t,e)}var kr,v,Ie,Oe=p(()=>{Ae();_t();kr=15e3;v=class{#e;#t=null;#r=null;#a=null;#o=null;#s=null;constructor(e){this.#e=e,e.binaryType="arraybuffer",e.addEventListener("message",r=>{let n=r.data,o=typeof n=="string"?new TextEncoder().encode(n):new Uint8Array(n);this.#t?.(o)}),e.addEventListener("open",()=>this.#r?.()),e.addEventListener("close",()=>this.#a?.()),e.addEventListener("error",r=>{this.#o?.(r.error?.message??"data channel error")}),e.addEventListener("bufferedamountlow",()=>this.#s?.())}isOpen(){return this.#e.readyState==="open"}send(e){this.#e.send(Lr(e))}bufferedAmount(){return this.#e.bufferedAmount}setBufferedAmountLowThreshold(e){this.#e.bufferedAmountLowThreshold=e}onBufferedAmountLow(e){this.#s=e}onMessage(e){this.#t=e}onOpen(e){this.#r=e}onClose(e){this.#a=e}onError(e){this.#o=e}close(){try{this.#e.close()}catch{}}},Ie=class t{remoteAddress;#e;#t;constructor(e,r,n){this.#e=e,this.remoteAddress=n;let o=e.createDataChannel(ee,{negotiated:!0,id:_e,ordered:!1,maxRetransmits:0});this.#t=new H({control:new v(r),datagram:new v(o),openChannel:s=>new v(e.createDataChannel(s)),closeTransport:()=>{try{e.close()}catch{}}}),e.addEventListener("connectionstatechange",()=>{let s=e.connectionState;s==="failed"?this.#t.onTransportFailed():s==="closed"&&this.#t.onTransportClosed()}),e.addEventListener("datachannel",s=>{let a=s.channel;a.label===Z||a.label===ee||this.#t.handleIncomingChannel(new v(a))})}get closed(){return this.#t.closed}static async dial(e,r={}){let n=r.signal??AbortSignal.timeout(kr);if(n.aborted)throw kt(n);let o=C(e),s=U(o.certhash),a=new RTCPeerConnection({}),i=a.createDataChannel(Z,{negotiated:!0,id:ve}),c=await a.createOffer(),l=ke(),d=await Le(s,l);await a.setLocalDescription({type:c.type,sdp:Me(c.sdp??"",l,d)}),await a.setRemoteDescription({type:"answer",sdp:Te(o,l,d)});let h=new t(a,i,{ip:o.ip,port:o.port});return await h.#r(n),h}#r(e){return new Promise((r,n)=>{let o=()=>{try{this.#e.close()}catch{}n(kt(e))};e.addEventListener("abort",o,{once:!0}),this.#t.established.then(()=>{e.removeEventListener("abort",o),r()},s=>{e.removeEventListener("abort",o),n(s)})})}openStream(e={}){return this.#t.openStream(e)}acceptStream(e={}){return this.#t.acceptStream(e)}async close(e){this.#t.close(e)}sendDatagram(e,r){return this.#t.sendDatagram(e,r)}receiveDatagram(e){return this.#t.receiveDatagram(e)}}});async function te(t,e){let r=await _(t,e);try{let n=await r.openStream({signal:e?.signal});return n.closed.finally(()=>{r.close()}),n}catch(n){throw await r.close(),n}}var Lt=p(()=>{Oe()});var Mt={};Vt(Mt,{dial:()=>_,formatAddress:()=>we,openStream:()=>te,parseAddress:()=>C});var Re=p(()=>{Oe();Lt();Ae()});var L=class{#e=[];#t=[];take(e){let r=this.#e.shift();return r!==void 0?Promise.resolve(r):new Promise((n,o)=>{let s={resolve:i=>{e?.removeEventListener("abort",a),n(i)},reject:i=>{e?.removeEventListener("abort",a),o(i)}},a=()=>{let i=this.#t.indexOf(s);i>=0&&this.#t.splice(i,1),o(e?.reason??new DOMException("aborted","AbortError"))};if(e?.aborted)return a();e?.addEventListener("abort",a,{once:!0}),this.#t.push(s)})}push(e){let r=this.#t.shift();r?r.resolve(e):this.#e.push(e)}pushFront(e){let r=this.#t.shift();r?r.resolve(e):this.#e.unshift(e)}remove(e){let r=this.#e.indexOf(e);return r<0?!1:(this.#e.splice(r,1),!0)}rejectAll(e){let r=this.#e.splice(0);for(let n of this.#t.splice(0))n.reject(e);return r}};var M=class{#e=[];#t=[];#r;#a;constructor(e){this.#a=e}dropped=0;take(e){let r=this.#e.shift();return r!==void 0?Promise.resolve(r):this.#r?Promise.reject(this.#r.err):new Promise((n,o)=>{let s={resolve:i=>{e?.removeEventListener("abort",a),n(i)},reject:i=>{e?.removeEventListener("abort",a),o(i)}},a=()=>{let i=this.#t.indexOf(s);i>=0&&this.#t.splice(i,1),o(e?.reason??new DOMException("aborted","AbortError"))};if(e?.aborted)return a();e?.addEventListener("abort",a,{once:!0}),this.#t.push(s)})}push(e){if(this.#r)return;let r=this.#t.shift();if(r)return r.resolve(e);for(this.#e.push(e);this.#e.length>this.#a;)this.#e.shift(),this.dropped++}close(e){if(!this.#r){this.#r={err:e};for(let r of this.#t.splice(0))r.reject(e)}}get size(){return this.#e.length}};var j=BigInt(4294967295),Be=BigInt(32);function zt(t,e=!1){return e?{h:Number(t&j),l:Number(t>>Be&j)}:{h:Number(t>>Be&j)|0,l:Number(t&j)|0}}function Fe(t,e=!1){let r=t.length,n=new Uint32Array(r),o=new Uint32Array(r);for(let s=0;s<r;s++){let{h:a,l:i}=zt(t[s],e);[n[s],o[s]]=[a,i]}return[n,o]}var Pe=(t,e,r)=>t<<r|e>>>32-r,He=(t,e,r)=>e<<r|t>>>32-r,Ne=(t,e,r)=>e<<r-32|t>>>64-r,$e=(t,e,r)=>t<<r-32|e>>>64-r;function Gt(t){return t instanceof Uint8Array||ArrayBuffer.isView(t)&&t.constructor.name==="Uint8Array"}function oe(t){if(!Number.isSafeInteger(t)||t<0)throw new Error("positive integer expected, got "+t)}function T(t,...e){if(!Gt(t))throw new Error("Uint8Array expected");if(e.length>0&&!e.includes(t.length))throw new Error("Uint8Array expected of length "+e+", got length="+t.length)}function se(t,e=!0){if(t.destroyed)throw new Error("Hash instance has been destroyed");if(e&&t.finished)throw new Error("Hash#digest() has already been called")}function je(t,e){T(t);let r=e.outputLen;if(t.length<r)throw new Error("digestInto() expects output buffer of length at least "+r)}function We(t){return new Uint32Array(t.buffer,t.byteOffset,Math.floor(t.byteLength/4))}function ie(...t){for(let e=0;e<t.length;e++)t[e].fill(0)}var Yt=new Uint8Array(new Uint32Array([287454020]).buffer)[0]===68;function Jt(t){return t<<24&4278190080|t<<8&16711680|t>>>8&65280|t>>>24&255}function Qt(t){for(let e=0;e<t.length;e++)t[e]=Jt(t[e]);return t}var ae=Yt?t=>t:Qt;function Zt(t){if(typeof t!="string")throw new Error("string expected");return new Uint8Array(new TextEncoder().encode(t))}function ce(t){return typeof t=="string"&&(t=Zt(t)),T(t),t}var W=class{};function Xe(t){let e=n=>t().update(ce(n)).digest(),r=t();return e.outputLen=r.outputLen,e.blockLen=r.blockLen,e.create=()=>t(),e}var er=BigInt(0),I=BigInt(1),tr=BigInt(2),rr=BigInt(7),nr=BigInt(256),or=BigInt(113),Ve=[],ze=[],Ge=[];for(let t=0,e=I,r=1,n=0;t<24;t++){[r,n]=[n,(2*r+3*n)%5],Ve.push(2*(5*n+r)),ze.push((t+1)*(t+2)/2%64);let o=er;for(let s=0;s<7;s++)e=(e<<I^(e>>rr)*or)%nr,e&tr&&(o^=I<<(I<<BigInt(s))-I);Ge.push(o)}var Ye=Fe(Ge,!0),sr=Ye[0],ir=Ye[1],qe=(t,e,r)=>r>32?Ne(t,e,r):Pe(t,e,r),Ke=(t,e,r)=>r>32?$e(t,e,r):He(t,e,r);function ar(t,e=24){let r=new Uint32Array(10);for(let n=24-e;n<24;n++){for(let a=0;a<10;a++)r[a]=t[a]^t[a+10]^t[a+20]^t[a+30]^t[a+40];for(let a=0;a<10;a+=2){let i=(a+8)%10,c=(a+2)%10,l=r[c],d=r[c+1],h=qe(l,d,1)^r[i],w=Ke(l,d,1)^r[i+1];for(let g=0;g<50;g+=10)t[a+g]^=h,t[a+g+1]^=w}let o=t[2],s=t[3];for(let a=0;a<24;a++){let i=ze[a],c=qe(o,s,i),l=Ke(o,s,i),d=Ve[a];o=t[d],s=t[d+1],t[d]=c,t[d+1]=l}for(let a=0;a<50;a+=10){for(let i=0;i<10;i++)r[i]=t[a+i];for(let i=0;i<10;i++)t[a+i]^=~r[(i+2)%10]&r[(i+4)%10]}t[0]^=sr[n],t[1]^=ir[n]}ie(r)}var le=class t extends W{constructor(e,r,n,o=!1,s=24){if(super(),this.pos=0,this.posOut=0,this.finished=!1,this.destroyed=!1,this.enableXOF=!1,this.blockLen=e,this.suffix=r,this.outputLen=n,this.enableXOF=o,this.rounds=s,oe(n),!(0<e&&e<200))throw new Error("only keccak-f1600 function is supported");this.state=new Uint8Array(200),this.state32=We(this.state)}clone(){return this._cloneInto()}keccak(){ae(this.state32),ar(this.state32,this.rounds),ae(this.state32),this.posOut=0,this.pos=0}update(e){se(this),e=ce(e),T(e);let{blockLen:r,state:n}=this,o=e.length;for(let s=0;s<o;){let a=Math.min(r-this.pos,o-s);for(let i=0;i<a;i++)n[this.pos++]^=e[s++];this.pos===r&&this.keccak()}return this}finish(){if(this.finished)return;this.finished=!0;let{state:e,suffix:r,pos:n,blockLen:o}=this;e[n]^=r,(r&128)!==0&&n===o-1&&this.keccak(),e[o-1]^=128,this.keccak()}writeInto(e){se(this,!1),T(e),this.finish();let r=this.state,{blockLen:n}=this;for(let o=0,s=e.length;o<s;){this.posOut>=n&&this.keccak();let a=Math.min(n-this.posOut,s-o);e.set(r.subarray(this.posOut,this.posOut+a),o),this.posOut+=a,o+=a}return e}xofInto(e){if(!this.enableXOF)throw new Error("XOF is not possible for this instance");return this.writeInto(e)}xof(e){return oe(e),this.xofInto(new Uint8Array(e))}digestInto(e){if(je(e,this),this.finished)throw new Error("digest() was already called");return this.writeInto(e),this.destroy(),e}digest(){return this.digestInto(new Uint8Array(this.outputLen))}destroy(){this.destroyed=!0,ie(this.state)}_cloneInto(e){let{blockLen:r,suffix:n,outputLen:o,rounds:s,enableXOF:a}=this;return e||(e=new t(r,n,o,a,s)),e.state32.set(this.state32),e.pos=this.pos,e.posOut=this.posOut,e.finished=this.finished,e.rounds=s,e.suffix=n,e.outputLen=o,e.enableXOF=a,e.destroyed=this.destroyed,e}},cr=(t,e,r)=>Xe(()=>new le(e,t,r));var de=cr(1,136,256/8);function O(t){let e="";for(let r of t)e+=r.toString(16).padStart(2,"0");return e}var lr=Qe("workerHash()"),dr=Qe("workerResolvers()");function Qe(t){return"0x"+O(de(new TextEncoder().encode(t))).slice(0,8)}function hr(t){let e=t.startsWith("0x")?t.slice(2):t,r=new Uint8Array(e.length/2);for(let n=0;n<r.length;n++)r[n]=parseInt(e.slice(n*2,n*2+2),16);return r}async function he(t,e){let r=await Je(t,e,lr),n=await Je(t,e,dr);return{workerHash:"0x"+ur(r),resolvers:pr(n)}}async function Je(t,e,r){let n=await t.request({method:"eth_call",params:[{to:e,data:r},"latest"]});if(typeof n!="string")throw new Error("eth_call did not return data");return hr(n)}var q=64*1024*1024;async function fr(t,e){let r=()=>new Error(`body exceeds the ${e}-byte bundle cap`);if(!t.body){let c=new Uint8Array(await t.arrayBuffer());if(c.byteLength>e)throw r();return c}let n=t.body.getReader(),o=[],s=0;for(;;){let{value:c,done:l}=await n.read();if(l)break;if(s+=c.byteLength,s>e)throw await n.cancel().catch(()=>{}),r();o.push(c)}let a=new Uint8Array(s),i=0;for(let c of o)a.set(c,i),i+=c.byteLength;return a}async function fe(t,e=q,r=[]){let n=[];for(let o of t.resolvers){let s;try{if(/^(https?|blob):/.test(o)){let i=await fetch(o);if(!i.ok)throw new Error(`HTTP ${i.status}`);s=await fr(i,e)}else{let i=r.find(c=>c.matches(o));if(!i){n.push(`${o}: unrecognized resolver kind (ignored)`);continue}s=await i.fetch(o,e)}}catch(i){n.push(`${o}: ${i.message}`);continue}let a="0x"+O(de(s));if(a!==t.workerHash){n.push(`${o}: hash mismatch (got ${a}, want ${t.workerHash})`);continue}return s}throw new Error(`no resolver yielded bytes matching workerHash: ${n.join("; ")}`)}function ur(t){if(t.length<32)throw new Error("short bytes32 return");return O(t.slice(0,32))}function X(t,e){if(e<0||e+32>t.length)throw new Error("ABI decode: word out of bounds");let r=0;for(let n=e;n<e+32;n++)if(r=r*256+t[n],r>Number.MAX_SAFE_INTEGER)throw new Error("ABI decode: word too large");return r}function pr(t){let e=X(t,0),r=X(t,e);if(e+32+r*32>t.length)throw new Error("ABI decode: array length out of bounds");let n=[],o=new TextDecoder;for(let s=0;s<r;s++){let a=e+32+X(t,e+32+s*32),i=X(t,a);if(a+32+i>t.length)throw new Error("ABI decode: string out of bounds");n.push(o.decode(t.slice(a+32,a+32+i)))}return n}function D(t,e="value"){return ue(t,e,new Set)}function ue(t,e,r){switch(typeof t){case"undefined":case"boolean":case"number":case"string":return t;case"object":break;default:throw R(e,typeof t)}if(t===null)return null;if(t instanceof Uint8Array){if(Ze(t.buffer))throw R(e,"a Uint8Array over a detached buffer");return new Uint8Array(t)}if(t instanceof ArrayBuffer){if(Ze(t))throw R(e,"a detached ArrayBuffer");return t.slice(0)}if(r.has(t))throw R(e,"a value that contains itself");r.add(t);try{if(Array.isArray(t)){let s=new Array(t.length);for(let a=0;a<t.length;a++)s[a]=ue(t[a],`${e}[${a}]`,r);return s}let n=Object.getPrototypeOf(t);if(n!==Object.prototype&&n!==null)throw R(e,mr(t));let o={};for(let s of Object.keys(t))Object.defineProperty(o,s,{value:ue(t[s],`${e}.${s}`,r),writable:!0,enumerable:!0,configurable:!0});return o}finally{r.delete(t)}}function Ze(t){return t.detached===!0}function mr(t){let e=t.constructor?.name;return typeof e=="string"&&e?`a ${e}`:"an object with a non-plain prototype"}function R(t,e){return new TypeError(`${t} is not a plain value (\xA79.4): got ${e}`)}var et=new Set(["method","headers","body","redirect","signal"]);function pe(t){if(!t)return;let e;for(let r of Object.keys(t))et.has(r)||(e??={},Object.defineProperty(e,r,{value:D(t[r],`init.${r}`),writable:!0,enumerable:!0,configurable:!0}));return e}var x=class extends Error{code;constructor(e){super(e.message),this.name=e.name,this.code=e.code}};function me(t){if(t instanceof Error){let e=t.code;return{name:t.name,message:t.message,...typeof e=="string"?{code:e}:{}}}return{name:"Error",message:String(t)}}Re();var Mr=class{#e;#t=1;#r=new Map;#a=new Map;#o=new Map;#s=new Map;constructor(t){this.#e=t,t.onmessage=e=>this.#n(e.data),t.start?.()}on(t,e){this.#a.set(t,e)}onEvent(t,e){this.#o.set(t,e)}emit(t,e,r){this.#i({t:"evt",topic:t,data:e},r)}call(t,e,r){let n=this.#t++;return new Promise((o,s)=>{let a;if(r?.signal){let i=r.signal;if(i.aborted){s(De());return}let c=()=>{this.#r.delete(n)&&(this.#i({t:"abort",id:n}),s(De()))};i.addEventListener("abort",c),a=()=>i.removeEventListener("abort",c)}this.#r.set(n,{resolve:o,reject:s,cleanup:a}),this.#i({t:"req",id:n,method:t,args:e},r?.transfer)})}#i(t,e){this.#e.postMessage(t,e??[])}async#n(t){switch(t.t){case"evt":{this.#o.get(t.topic)?.(t.data);return}case"abort":{this.#s.get(t.id)?.abort(De());return}case"res":{let e=this.#r.get(t.id);if(!e)return;this.#r.delete(t.id),e.cleanup?.(),t.ok?e.resolve(t.value):e.reject(new x(t.error));return}case"req":{let e=this.#a.get(t.method);if(!e){this.#i({t:"res",id:t.id,ok:!1,error:{name:"Error",message:`no handler: ${t.method}`}});return}let r=new AbortController;this.#s.set(t.id,r);try{let n=await e(t.args,{signal:r.signal});this.#i({t:"res",id:t.id,ok:!0,value:n.value},n.transfer)}catch(n){this.#i({t:"res",id:t.id,ok:!1,error:me(n)})}finally{this.#s.delete(t.id)}return}}}};function De(){return new DOMException("The operation was aborted.","AbortError")}function Tr(t){let e=new Map,r=new Map,n=1,o=i=>{let c=n++;return r.set(c,i),i.closed.then(l=>{r.delete(c),t.emit("stream.closed",{streamId:c,info:l})}),{value:{streamId:c,readable:i.readable,writable:i.writable},transfer:[i.readable,i.writable]}},s=i=>{let c=e.get(i);if(!c)throw new Error(`unknown connId ${i}`);return c},a=i=>{let c=r.get(i);if(!c)throw new Error(`unknown streamId ${i}`);return c};return t.on("kps.dial",async({addr:i},{signal:c})=>{let l=await _(i,{signal:c}),d=n++;return e.set(d,l),l.closed.then(h=>{e.delete(d),t.emit("conn.closed",{connId:d,info:h})}),{value:{connId:d,remoteAddress:l.remoteAddress}}}),t.on("kps.openStream",async({addr:i},{signal:c})=>{let l=await te(i,{signal:c});return o(l)}),t.on("conn.openStream",async({connId:i},{signal:c})=>o(await s(i).openStream({signal:c}))),t.on("conn.acceptStream",async({connId:i},{signal:c})=>o(await s(i).acceptStream({signal:c}))),t.on("conn.close",async({connId:i,reason:c})=>(await s(i).close(c),e.delete(i),{value:void 0})),t.on("conn.sendDatagram",async({connId:i,data:c},{signal:l})=>(await s(i).sendDatagram(c,{signal:l}),{value:void 0})),t.on("conn.receiveDatagram",async({connId:i},{signal:c})=>({value:await s(i).receiveDatagram({signal:c})})),t.on("stream.closeWrite",async({streamId:i})=>(await a(i).closeWrite(),{value:void 0})),t.on("stream.cancelRead",async({streamId:i,reason:c})=>(await a(i).cancelRead(c),{value:void 0})),t.on("stream.resetWrite",async({streamId:i,reason:c})=>(await a(i).resetWrite(c),{value:void 0})),t.on("stream.close",async({streamId:i,reason:c})=>(await a(i).close(c),r.delete(i),{value:void 0})),()=>{for(let i of r.values())i.close({code:"closed"}).catch(()=>{});for(let i of e.values())i.close({code:"closed"});r.clear(),e.clear()}}async function Ir(t,e){let r=pe(e);if(t instanceof Request){let d=e?.body instanceof ReadableStream,h=e?new Request(t,{...d?{duplex:"half"}:{},...e}):t,w=[];h.headers.forEach((E,y)=>w.push([y,E]));let g={method:h.method,headers:w,redirect:h.redirect,hasSignal:!0};r&&(g.forwarded=r);let b=[];return h.body&&(g.body=h.body,b.push(h.body)),{url:h.url,requestInit:g,transfer:b,signal:h.signal}}let n=typeof t=="string"?t:t.href;if(!e)return{url:n};let o=e,s=[],a,i;if(o.body!=null)if(o.body instanceof ReadableStream)a=o.body,s.push(o.body);else if(typeof o.body=="string")a=new TextEncoder().encode(o.body),s.push(a.buffer);else if(o.body instanceof Uint8Array||o.body instanceof ArrayBuffer)a=o.body instanceof Uint8Array?o.body:new Uint8Array(o.body);else{let d=new Response(o.body);a=new Uint8Array(await d.arrayBuffer()),i=d.headers.get("content-type")??void 0,s.push(a.buffer)}let c={};o.method&&(c.method=o.method);let l=Or(o.headers)??[];return i&&!l.some(([d])=>d.toLowerCase()==="content-type")&&l.push(["content-type",i]),l.length&&(c.headers=l),a!==void 0&&(c.body=a),o.redirect&&(c.redirect=o.redirect),o.signal&&(c.hasSignal=!0),r&&(c.forwarded=r),{url:n,requestInit:c,transfer:s,signal:o.signal??void 0}}function Or(t){if(!t)return;let e=[];if(t instanceof Headers)t.forEach((r,n)=>e.push([n,r]));else if(Array.isArray(t))for(let[r,n]of t)e.push([r,n]);else for(let[r,n]of Object.entries(t))e.push([r,String(n)]);return e}var Rr="anon-rpc-harness",Ce="kv";function Dr(){return typeof indexedDB>"u"?Promise.resolve(new Ur):Cr.open()}function N(t){return new Promise((e,r)=>{t.onsuccess=()=>e(t.result),t.onerror=()=>r(t.error)})}var Cr=class Tt{#e;constructor(e){this.#e=e}static async open(){let e=indexedDB.open(Rr,1);return e.onupgradeneeded=()=>{e.result.createObjectStore(Ce)},new Tt(await N(e))}#t(e){return this.#e.transaction(Ce,e).objectStore(Ce)}async get(e,r){return await N(this.#t("readonly").get([e,r]))}async set(e,r,n){await N(this.#t("readwrite").put(n,[e,r]))}async delete(e,r){await N(this.#t("readwrite").delete([e,r]))}async has(e,r){return await N(this.#t("readonly").getKey([e,r]))!==void 0}async listKeys(e,r=""){let n=[];return await this.#r("readonly",e,r,o=>{n.push(o.key[1])}),n}async clear(e,r=""){await this.#r("readwrite",e,r,n=>{n.delete()})}#r(e,r,n,o){return new Promise((s,a)=>{let i=this.#t(e),c=IDBKeyRange.lowerBound([r,n]),l=e==="readwrite"?i.openCursor(c):i.openKeyCursor(c);l.onsuccess=()=>{let d=l.result;if(!d)return s();let[h,w]=d.key;if(h!==r||!w.startsWith(n))return s();o(d),d.continue()},l.onerror=()=>a(l.error)})}},Ur=class{#e=new Map;#t(t){let e=this.#e.get(t);return e||this.#e.set(t,e=new Map),e}async get(t,e){return this.#t(t).get(e)}async set(t,e,r){this.#t(t).set(e,r)}async delete(t,e){this.#t(t).delete(e)}async has(t,e){return this.#t(t).has(e)}async listKeys(t,e=""){return[...this.#t(t).keys()].filter(r=>r.startsWith(e))}async clear(t,e=""){let r=this.#t(t);if(!e)return r.clear();for(let n of[...r.keys()])n.startsWith(e)&&r.delete(n)}},Br=new TextEncoder,$=`\r
`;function Fr(t){if(!t.startsWith("kps:"))return;let e=t.slice(4),r=e.indexOf("/");if(r<=0)throw new Error("malformed kps resolver: missing /path");let n=e.slice(0,r),o=e.slice(r);if(n.split(":").length<3)throw new Error("malformed kps resolver: bad address");return{addr:n,path:o}}function Pr(t,e,r=[]){let n=r.length?`Accept-Encoding: ${r.join(", ")}${$}`:"";return Br.encode(`GET ${t} HTTP/1.1${$}Host: ${e}${$}${n}${$}`)}var It=[["zstd",["zstd"]],["br",["br","brotli"]],["gzip",["gzip"]],["deflate",["deflate"]]];function Ot(){return globalThis.DecompressionStream}function Rt(t){let e=Ot();if(e)for(let r of It.find(([n])=>n===t)?.[1]??[])try{return new e(r),r}catch{}}function Hr(){return It.map(([t])=>t).filter(t=>Rt(t)!==void 0)}async function Nr(t,e,r){let n=Ot(),o=Rt(t);if(!n||o===void 0)throw new Error(`undecodable Content-Encoding: ${t}`);let a=new Blob([e]).stream().pipeThrough(new n(o)).getReader(),i=[],c=0;for(;;){let{value:h,done:w}=await a.read();if(w)break;if(c+=h.byteLength,c>r)throw await a.cancel().catch(()=>{}),new Error(`decoded body exceeds the ${r}-byte bundle cap`);i.push(h)}let l=new Uint8Array(c),d=0;for(let h of i)l.set(h,d),d+=h.byteLength;return l}function $r(t){let e=jr(t);if(e<0)throw new Error("no header terminator in response");let n=new TextDecoder("utf-8",{fatal:!1}).decode(t.subarray(0,e)).split($),o=/^HTTP\/1\.1 (\d{3})(?: |$)/.exec(n[0]);if(!o)throw new Error(`malformed status line: ${JSON.stringify(n[0].slice(0,80))}`);let s=Number(o[1]),a=[];for(let i of n.slice(1)){if(i==="")continue;let c=i.indexOf(":");if(c<=0)throw new Error(`malformed header line: ${JSON.stringify(i.slice(0,80))}`);let l=i.slice(0,c).trim().toLowerCase(),d=i.slice(c+1).trim();if(l==="transfer-encoding")throw new Error("forbidden Transfer-Encoding in response");a.push([l,d])}return{status:s,headers:a,body:t.subarray(e+4)}}function jr(t){for(let e=0;e+3<t.length;e++)if(t[e]===13&&t[e+1]===10&&t[e+2]===13&&t[e+3]===10)return e;return-1}async function Wr(t,e,r){let{openStream:n}=await Promise.resolve().then(()=>(Re(),Mt)),o=await n(t);try{let s=t.slice(t.lastIndexOf(":")+1),a=Hr(),i=o.writable.getWriter();await i.write(Pr(e,s,a)),await i.close();let c=o.readable.getReader(),l=[],d=0,h=64*1024;for(;;){let{value:y,done:qt}=await c.read();if(qt)break;if(d+=y.byteLength,d>r+h)throw await c.cancel().catch(()=>{}),new Error(`response exceeds the ${r}-byte bundle cap`);l.push(y)}let w=new Uint8Array(d),g=0;for(let y of l)w.set(y,g),g+=y.byteLength;let b=$r(w);if(b.status!==200)throw new Error(`HTTP ${b.status}`);let E=b.headers.find(([y])=>y==="content-encoding")?.[1].toLowerCase();if(E&&E!=="identity"){if(!a.includes(E))throw new Error(`unadvertised Content-Encoding: ${E}`);return Nr(E,b.body,r)}if(b.body.byteLength>r)throw new Error(`body exceeds the ${r}-byte bundle cap`);return b.body}finally{await o.close().catch(()=>{})}}var Xr={matches:t=>t.startsWith("kps:"),fetch:(t,e)=>{let{addr:r,path:n}=Fr(t);return Wr(r,n,e)}},qr=1e3,Dt=class{ready;fetch;#e;#t;#r;#a;#o;#s;#i=new L;#n=new M(qr);#d=!1;#h=new Map;#p=1;#m;#u;#l;#f;constructor(t){this.#e=t,this.#t=D(t.config,"config"),this.ready=new Promise((e,r)=>{this.#m=e,this.#u=r}),this.ready.catch(()=>{}),this.fetch=this.#E.bind(this),this.#g().catch(e=>this.#c(e))}#c(t){if(this.#l===void 0){this.#l=t,this.#u(t);for(let e of this.#h.values())e.cleanup?.(),e.reject(t);this.#h.clear(),this.#i.rejectAll(t),this.#n.close(t)}}async#g(){let t=this.#e.preExisting?.rpcProvider;if(!t)throw new Error("preExisting.rpcProvider is required to read the specifier");let e=await he(t,this.#e.address),r=await fe(e,q,[Xr]),n=new MessageChannel,o=new Mr(n.port1);this.#r=o,this.#w(o);let s=document.createElement("iframe");s.setAttribute("sandbox","allow-scripts"),s.style.display="none",this.#e.iframeUrl?s.src=Kr(this.#e.iframeUrl):s.srcdoc=`<!doctype html><meta charset="utf-8"><script>"use strict";
(() => {
  // src/iframe/iframe-boot.ts
  (() => {
    parent.postMessage({ kind: "iframe-ready" }, "*");
    const onInit = (ev) => {
      if (ev.source !== parent || ev.data?.kind !== "init") return;
      removeEventListener("message", onInit);
      const port = ev.ports[0];
      const runtimeSource = ev.data.runtimeSource;
      const bundleBytes = ev.data.bundleBytes;
      const blob = new Blob([runtimeSource], { type: "text/javascript" });
      const worker = new Worker(URL.createObjectURL(blob));
      worker.postMessage({ kind: "init", port, bundleBytes, config: ev.data.config }, [port]);
      worker.addEventListener("error", (e) => {
        parent.postMessage({ kind: "worker-error", message: e.message }, "*");
      });
    };
    addEventListener("message", onInit);
  })();
})();
<\/script>`,this.#a=s;let a=new Promise(i=>{let c=l=>{l.source===s.contentWindow&&(l.data?.kind==="iframe-ready"&&i(),l.data?.kind==="worker-error"&&this.#c(new Error(`worker error: ${l.data.message}`)))};this.#s=c,window.addEventListener("message",c)});document.body.appendChild(s),await a,s.contentWindow.postMessage({kind:"init",runtimeSource:`"use strict";
(() => {
  // ../harness-core/dist/errors.js
  var RpcError = class extends Error {
    code;
    constructor(e) {
      super(e.message);
      this.name = e.name;
      this.code = e.code;
    }
  };
  function serializeError(err) {
    if (err instanceof Error) {
      const code = err.code;
      return {
        name: err.name,
        message: err.message,
        ...typeof code === "string" ? { code } : {}
      };
    }
    return { name: "Error", message: String(err) };
  }

  // src/protocol.ts
  var PortRpc = class {
    #port;
    #nextId = 1;
    #pending = /* @__PURE__ */ new Map();
    #handlers = /* @__PURE__ */ new Map();
    #events = /* @__PURE__ */ new Map();
    // AbortControllers for in-flight inbound requests, keyed by caller-side id.
    #inbound = /* @__PURE__ */ new Map();
    constructor(port) {
      this.#port = port;
      port.onmessage = (ev) => this.#onMessage(ev.data);
      port.start?.();
    }
    /** Register a handler for an inbound method. */
    on(method, handler) {
      this.#handlers.set(method, handler);
    }
    /** Register a handler for an inbound fire-and-forget event. */
    onEvent(topic, handler) {
      this.#events.set(topic, handler);
    }
    /** Fire-and-forget event to the peer. */
    emit(topic, data, transfer) {
      this.#post({ t: "evt", topic, data }, transfer);
    }
    /** Call a remote method and await its result. */
    call(method, args, opts) {
      const id = this.#nextId++;
      return new Promise((resolve, reject) => {
        let cleanup;
        if (opts?.signal) {
          const signal = opts.signal;
          if (signal.aborted) {
            reject(abortError());
            return;
          }
          const onAbort = () => {
            if (!this.#pending.delete(id)) return;
            this.#post({ t: "abort", id });
            reject(abortError());
          };
          signal.addEventListener("abort", onAbort);
          cleanup = () => signal.removeEventListener("abort", onAbort);
        }
        this.#pending.set(id, {
          resolve,
          reject,
          cleanup
        });
        this.#post({ t: "req", id, method, args }, opts?.transfer);
      });
    }
    #post(msg, transfer) {
      this.#port.postMessage(msg, transfer ?? []);
    }
    async #onMessage(msg) {
      switch (msg.t) {
        case "evt": {
          this.#events.get(msg.topic)?.(msg.data);
          return;
        }
        case "abort": {
          this.#inbound.get(msg.id)?.abort(abortError());
          return;
        }
        case "res": {
          const p = this.#pending.get(msg.id);
          if (!p) return;
          this.#pending.delete(msg.id);
          p.cleanup?.();
          if (msg.ok) p.resolve(msg.value);
          else p.reject(new RpcError(msg.error));
          return;
        }
        case "req": {
          const handler = this.#handlers.get(msg.method);
          if (!handler) {
            this.#post({
              t: "res",
              id: msg.id,
              ok: false,
              error: { name: "Error", message: \`no handler: \${msg.method}\` }
            });
            return;
          }
          const ac = new AbortController();
          this.#inbound.set(msg.id, ac);
          try {
            const result = await handler(msg.args, { signal: ac.signal });
            this.#post(
              { t: "res", id: msg.id, ok: true, value: result.value },
              result.transfer
            );
          } catch (err) {
            this.#post({
              t: "res",
              id: msg.id,
              ok: false,
              error: serializeError(err)
            });
          } finally {
            this.#inbound.delete(msg.id);
          }
          return;
        }
      }
    }
  };
  function abortError() {
    return new DOMException("The operation was aborted.", "AbortError");
  }

  // src/worker/anon-rpc-worker-api.ts
  function makeWorkerApi(rpc, config) {
    const callAborts = /* @__PURE__ */ new Map();
    const preAborted = /* @__PURE__ */ new Set();
    rpc.onEvent("call-abort", ({ callId }) => {
      const ac = callAborts.get(callId);
      if (ac) ac.abort(new DOMException("aborted", "AbortError"));
      else preAborted.add(callId);
    });
    const streamClosed = /* @__PURE__ */ new Map();
    const connClosed = /* @__PURE__ */ new Map();
    rpc.onEvent("stream.closed", ({ streamId, info }) => {
      streamClosed.get(streamId)?.(info);
      streamClosed.delete(streamId);
    });
    rpc.onEvent("conn.closed", ({ connId, info }) => {
      connClosed.get(connId)?.(info);
      connClosed.delete(connId);
    });
    function makeStream(p) {
      const closed = new Promise((resolve) => streamClosed.set(p.streamId, resolve));
      return {
        readable: p.readable,
        writable: p.writable,
        closeWrite: () => rpc.call("stream.closeWrite", { streamId: p.streamId }),
        cancelRead: (reason) => rpc.call("stream.cancelRead", { streamId: p.streamId, reason }),
        resetWrite: (reason) => rpc.call("stream.resetWrite", { streamId: p.streamId, reason }),
        close: (reason) => rpc.call("stream.close", { streamId: p.streamId, reason }),
        closed
      };
    }
    function makeConn(connId, remoteAddress) {
      const closed = new Promise((resolve) => connClosed.set(connId, resolve));
      return {
        remoteAddress,
        openStream: async (opts) => makeStream(await rpc.call("conn.openStream", { connId }, sigOpt(opts))),
        acceptStream: async (opts) => makeStream(await rpc.call("conn.acceptStream", { connId }, sigOpt(opts))),
        close: (reason) => rpc.call("conn.close", { connId, reason }),
        sendDatagram: (data, opts) => rpc.call("conn.sendDatagram", { connId, data }, sigOpt(opts)),
        receiveDatagram: (opts) => rpc.call("conn.receiveDatagram", { connId }, sigOpt(opts)),
        closed
      };
    }
    const kps = {
      dial: async (addr, opts) => {
        const { connId, remoteAddress } = await rpc.call("kps.dial", { addr }, sigOpt(opts));
        return makeConn(connId, remoteAddress);
      },
      openStream: async (addr, opts) => makeStream(await rpc.call("kps.openStream", { addr }, sigOpt(opts)))
    };
    const storage = {
      get: (key, opts) => rpc.call("storage.get", { key }, sigOpt(opts)),
      set: (key, value, opts) => rpc.call("storage.set", { key, value }, sigOpt(opts)),
      delete: (key, opts) => rpc.call("storage.delete", { key }, sigOpt(opts)),
      has: (key, opts) => rpc.call("storage.has", { key }, sigOpt(opts)),
      clear: (opts) => rpc.call("storage.clear", { prefix: opts?.prefix }, sigOpt(opts)),
      list: (opts) => listKeys(rpc, opts?.prefix, opts?.signal)
    };
    const log = {
      debug: (...args) => rpc.emit("log", { level: "debug", args }),
      info: (...args) => rpc.emit("log", { level: "info", args }),
      warn: (...args) => rpc.emit("log", { level: "warn", args }),
      error: (...args) => rpc.emit("log", { level: "error", args })
    };
    function acceptCall(opts) {
      const abortErr = () => new DOMException("aborted", "AbortError");
      const signal = opts?.signal;
      const toCall = (r) => makeFetchCall(rpc, callAborts, preAborted, r.callId, r.url, r.requestInit);
      if (signal?.aborted) return Promise.reject(signal.reason ?? abortErr());
      const pending = rpc.call("acceptCall", {});
      if (!signal) return pending.then(toCall);
      return new Promise((resolve, reject) => {
        let settled = false;
        const onAbort = () => {
          if (settled) return;
          settled = true;
          pending.then((r) => rpc.emit("requeue-call", { callId: r.callId }), () => {
          });
          reject(signal.reason ?? abortErr());
        };
        signal.addEventListener("abort", onAbort, { once: true });
        pending.then(
          (r) => {
            if (settled) return;
            settled = true;
            signal.removeEventListener("abort", onAbort);
            resolve(toCall(r));
          },
          (e) => {
            if (settled) return;
            settled = true;
            signal.removeEventListener("abort", onAbort);
            reject(e);
          }
        );
      });
    }
    return {
      signalReady: () => rpc.emit("ready", {}),
      // Failure finality (\xA77: later signals ignored) is enforced host-side \u2014
      // #fail is one-shot and resolving an already-rejected ready is a no-op.
      signalFailed: (reason) => rpc.emit("failed", { reason }),
      acceptCall,
      config,
      kps,
      storage,
      log
    };
  }
  function makeFetchCall(rpc, callAborts, preAborted, callId, url, wireInit) {
    let requestInit;
    if (wireInit) {
      const { hasSignal, forwarded, ...rest } = wireInit;
      requestInit = { ...forwarded, ...rest };
      if (hasSignal) {
        const ac = new AbortController();
        callAborts.set(callId, ac);
        requestInit = { ...requestInit, signal: ac.signal };
        if (preAborted.delete(callId)) ac.abort(new DOMException("aborted", "AbortError"));
      }
    }
    let responded = false;
    return {
      kind: "fetch",
      url,
      ...requestInit ? { requestInit } : {},
      respond(response) {
        if (responded) throw new Error("respond() called more than once");
        responded = true;
        Promise.resolve(response).then((r) => {
          const transfer = r.body instanceof ReadableStream ? [r.body] : r.body instanceof Uint8Array ? [r.body.buffer] : [];
          return rpc.call("respond", { callId, ok: true, response: r }, { transfer });
        }).catch(
          (e) => (
            // Carry name/code across the boundary (\xA712): host logic may branch
            // on code, never on message text.
            rpc.call("respond", { callId, ok: false, error: serializeError(e) })
          )
        ).catch(() => {
        }).finally(() => callAborts.delete(callId));
      }
    };
  }
  async function* listKeys(rpc, prefix, signal) {
    const keys = await rpc.call("storage.list", { prefix }, signal ? { signal } : void 0);
    for (const k of keys) yield k;
  }
  function sigOpt(opts) {
    return opts?.signal ? { signal: opts.signal } : void 0;
  }

  // src/worker/worker-runtime.ts
  var importScripts = (url) => (
    // eslint-disable-next-line no-restricted-globals
    self.importScripts(url)
  );
  function bundleScriptUrl(bundle) {
    const probeUrl = URL.createObjectURL(new Blob([";"], { type: "text/javascript" }));
    try {
      importScripts(probeUrl);
      return URL.createObjectURL(bundle);
    } catch {
      return new FileReaderSync().readAsDataURL(bundle);
    } finally {
      URL.revokeObjectURL(probeUrl);
    }
  }
  addEventListener("message", function onInit(ev) {
    if (ev.data?.kind !== "init") return;
    removeEventListener("message", onInit);
    const port = ev.data.port;
    const bundleBytes = ev.data.bundleBytes;
    const config = ev.data.config;
    const rpc = new PortRpc(port);
    const api = makeWorkerApi(rpc, config);
    globalThis.anonRpcWorker = api;
    try {
      const blob = new Blob([bundleBytes], { type: "text/javascript" });
      importScripts(bundleScriptUrl(blob));
    } catch (err) {
      const message = err?.message ?? String(err);
      api.log.error("worker bundle failed to load:", message);
      rpc.emit("boot-error", { message });
    }
  });
})();
`,bundleBytes:r,config:this.#t},"*",[n.port2])}#w(t){this.#o=Tr(t),t.onEvent("ready",()=>this.#m()),t.onEvent("boot-error",({message:n})=>{this.#c(new Error(`worker bundle failed to load: ${n}`))}),t.onEvent("failed",({reason:n})=>{this.#c(new x({name:"WorkerFailedError",message:n?.message??"worker signalled failure",code:n?.code}))}),t.onEvent("requeue-call",({callId:n})=>{let o=this.#h.get(n);o&&this.#i.pushFront(o)}),t.onEvent("log",({level:n,args:o})=>{if(this.#n.push({level:n,args:o}),this.#d)return;(console[n]??console.log).call(console,"[worker]",...o.map(Vr))}),t.on("acceptCall",async(n,{signal:o})=>{let s=await this.#i.take(o);return{value:{callId:s.callId,url:s.url,requestInit:s.requestInit},transfer:s.bodyTransfer??[]}}),t.on("respond",async n=>{let o=this.#h.get(n.callId);if(!o)return{value:void 0};if(this.#h.delete(n.callId),o.cleanup?.(),n.ok&&n.response)try{o.resolve(zr(n.response))}catch(s){o.reject(s)}else o.reject(new x(n.error??{name:"Error",message:"worker failed the call"}));return{value:void 0}});let e=this.#e.address.toLowerCase(),r=()=>this.#f??=Dr();t.on("storage.get",async({key:n})=>({value:await(await r()).get(e,n)})),t.on("storage.set",async({key:n,value:o})=>(await(await r()).set(e,n,o),{value:void 0})),t.on("storage.delete",async({key:n})=>(await(await r()).delete(e,n),{value:void 0})),t.on("storage.has",async({key:n})=>({value:await(await r()).has(e,n)})),t.on("storage.list",async({prefix:n})=>({value:await(await r()).listKeys(e,n)})),t.on("storage.clear",async({prefix:n})=>(await(await r()).clear(e,n),{value:void 0}))}async#E(t,e){if(this.#l!==void 0)throw this.#l;let{url:r,requestInit:n,transfer:o,signal:s}=await Ir(t,e),a=this.#p++;return new Promise((i,c)=>{let l={callId:a,url:r,requestInit:n,bodyTransfer:o,resolve:i,reject:c};if(this.#h.set(a,l),s){let d=()=>{this.#i.remove(l)||this.#r?.emit("call-abort",{callId:a}),this.#h.delete(a)&&c(s.reason??new DOMException("aborted","AbortError"))};if(s.aborted){this.#h.delete(a),c(s.reason??new DOMException("aborted","AbortError"));return}s.addEventListener("abort",d,{once:!0}),l.cleanup=()=>s.removeEventListener("abort",d)}this.#i.push(l)})}acceptLog(t){return this.#d=!0,this.#n.take(t?.signal)}close(){this.#o?.(),this.#s&&window.removeEventListener("message",this.#s),this.#a?.remove(),this.#c(new Error("worker closed"))}};function Kr(t){let e;try{e=new URL(t,location.href)}catch{throw new Error(`iframeUrl is not a valid URL: ${t}`)}if(e.origin!==location.origin)throw new Error(`iframeUrl must be same-origin with the host (${location.origin}), got ${e.origin} \u2014 a cross-origin bootstrap would control the isolation boundary (\xA76)`);return e.href}function Vr(t){return t instanceof Uint8Array?`<${t.byteLength} bytes>`:t}function zr(t){let e=new Headers;for(let[s,a]of t.headers)e.append(s,a);let r=t.status,n=r===204||r===205||r===304?null:t.body,o=new Response(n,{status:r,headers:e});return t.url&&Object.defineProperty(o,"url",{value:t.url}),o}function Ct(t){let e="";for(let r=0;r<t.length;r+=32768)e+=String.fromCharCode(...t.subarray(r,r+32768));return btoa(e)}function Ut(t){let e=atob(t),r=new Uint8Array(e.length);for(let n=0;n<e.length;n++)r[n]=e.charCodeAt(n);return r}function re(t){return String(t).replace(/\b[a-z][a-z0-9+.-]*:\/\/\S+/gi,"<url>")}var Gr=2e4,Yr=20,k={notStarted:"NOT_STARTED",workerFailed:"WORKER_FAILED",timeout:"TIMEOUT",fetchFailed:"FETCH_FAILED"},u;function Jr(t){return{async request({method:e,params:r}){let n=await fetch(t,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:1,method:e,params:r}),signal:AbortSignal.timeout(Gr)});if(!n.ok)throw new Error(`the bootstrap RPC answered ${n.status}`);let{result:o,error:s}=await n.json();if(s)throw new Error(`the bootstrap RPC refused the read (${s.code??"error"})`);return o}}}var Ue=class{constructor({specifier:e,bootstrapRpcUrl:r,config:n,debug:o},s){this.specifier=e,this.phase="starting",this.lastError=null,this.lines=[],this.requests=0,this.failures=0,this.worker=new Dt({address:e,config:n??{},preExisting:{rpcProvider:Jr(r)},iframeUrl:new URL("sandbox.html",location.href).href}),this.ready=this.worker.ready.then(()=>{this.phase="ready",s("status",this.status())},a=>{this.phase="failed",this.lastError=re(a?.message??a),s("status",this.status())}),this.#e(s,o)}async#e(e,r){try{for(;;){let{level:n,args:o}=await this.worker.acceptLog(),s=o.map(i=>typeof i=="string"?i:JSON.stringify(i)).join(" "),a=`${n}: ${re(s)}`;this.lines.push(a),this.lines.length>Yr&&this.lines.shift(),r&&e("log",a)}}catch{}}status(){return{phase:this.phase,specifier:this.specifier,requests:this.requests,failures:this.failures,lastError:this.lastError,lines:this.lines}}async fetch({url:e,method:r,headers:n,bodyBase64:o,isolationKey:s,timeoutMs:a}){this.requests+=1;try{let i=await this.worker.fetch(e,{method:r,headers:n,body:o?Ut(o):void 0,signal:AbortSignal.timeout(a),anonOptions:{isolationKey:s}}),c=new Uint8Array(await i.arrayBuffer()),l=[];return i.headers.forEach((d,h)=>l.push([h,d])),{ok:!0,status:i.status,headers:l,bodyBase64:Ct(c)}}catch(i){return this.failures+=1,{ok:!1,code:i?.name==="AbortError"||i?.name==="TimeoutError"?k.timeout:this.phase==="failed"?k.workerFailed:k.fetchFailed,message:re(i?.message??i)}}}close(){this.phase="idle",this.worker.close()}};function Ft(t,e){if(typeof t?.specifier!="string"||typeof t?.bootstrapRpcUrl!="string")throw jt("specifier and bootstrapRpcUrl are required");return u!==void 0&&u.specifier===t.specifier&&u.phase!=="failed"||(u?.close(),u=new Ue(t,e)),u.status()}async function Pt(){if(u===void 0)throw Bt(k.notStarted,"no worker is started");if(await u.ready,u.phase!=="ready")throw Bt(k.workerFailed,u.lastError??"the worker failed");return u.status()}function Ht(t){if(u===void 0)return{ok:!1,code:k.notStarted,message:"no worker is started"};if(typeof t?.url!="string"||typeof t?.method!="string")throw jt("url and method are required");return u.fetch({url:t.url,method:t.method,headers:Array.isArray(t.headers)?t.headers:[],bodyBase64:typeof t.bodyBase64=="string"?t.bodyBase64:"",isolationKey:typeof t.isolationKey=="string"?t.isolationKey:void 0,timeoutMs:Number.isFinite(t.timeoutMs)&&t.timeoutMs>0?t.timeoutMs:6e4})}function Nt(){return u?.status()??{phase:"idle",specifier:null,requests:0,failures:0,lastError:null,lines:[]}}function $t(){return u?.close(),u=void 0,null}var S=class extends Error{constructor(e,r){super(r),this.code=e}},Bt=(t,e)=>new S(t,e),jt=t=>new S("BAD_REQUEST",t);var Zr="vizor-anon-rpc-init",Wt={start:Ft,awaitReady:Pt,fetch:Ht,status:Nt,stop:$t},ne,Xt=(t,e)=>ne({event:t,data:e});function en(t){if(Object.hasOwn(Wt,t))return Wt[t];throw new S("BAD_REQUEST",`unknown method ${t}`)}async function tn(t){let e;try{e=JSON.parse(t)}catch{return}let{id:r,method:n,params:o}=e??{};if(Number.isSafeInteger(r))try{ne({id:r,result:await en(n)(o??{},Xt)??null})}catch(s){let a=s instanceof S?s.code:"FAILED";ne({id:r,error:{code:a,message:String(s?.message??s)}})}}function rn(){let t;window.addEventListener("message",e=>{t!==void 0||e.source!==null||e.data!==Zr||e.ports.length!==1||([t]=e.ports,ne=r=>t.postMessage(JSON.stringify(r)),t.onmessage=({data:r})=>tn(r),Xt("ready",null))})}rn();
