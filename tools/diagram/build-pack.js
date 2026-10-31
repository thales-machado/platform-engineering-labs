const L=require("@iconify-json/logos/icons.json"),S=require("@iconify-json/simple-icons/icons.json"),M=require("@iconify-json/mdi/icons.json");
const get=(p,k)=>{const i=p.icons[k]||p.icons[(p.aliases||{})[k]?.parent];return {body:i.body,width:i.width||p.width||24,height:i.height||p.height||24};};
const tint=(i,c)=>({...i,body:i.body.replace(/currentColor/g,c).replace(/<path /g,`<path fill="${c}" `)});
const icons={
  kubernetes:get(L,"kubernetes"), docker:get(L,"docker-icon"), prometheus:get(L,"prometheus"),
  grafana:get(L,"grafana"), argo:get(L,"argo-icon"), helm:tint(get(L,"helm"),"#e2e8f0"), postgres:get(L,"postgresql"),
  github:tint(get(S,"github"),"#f8fafc"), debian:get(L,"debian"), rpi:get(L,"raspberry-pi"), amd:tint(get(S,"amd"),"#e2e8f0"),
  etcd:get(L,"etcd"), cilium:tint(get(S,"cilium"),"#F8C517"), traefik:tint(get(S,"traefikproxy"),"#24A1C1"),
  containerd:tint(get(S,"containerd"),"#cbd5e1"), client:tint(get(M,"laptop"),"#e2e8f0"),
  lb:tint(get(M,"scale-balance"),"#22d3ee"), loki:tint(get(M,"file-document-multiple-outline"),"#fb923c"),
  slo:tint(get(M,"target"),"#fb923c"), disk:tint(get(M,"harddisk"),"#a5b4fc"), calico:tint(get(M,"lan"),"#fb923c"),
  rollouts:get(L,"argo-icon"), app:tint(get(M,"cube-outline"),"#a5b4fc"),
};
for (const [k,v] of Object.entries(icons)) if(!v.body) throw k;
require("fs").writeFileSync(require("path").join(__dirname,"lab.json"),JSON.stringify({prefix:"lab",icons}));
console.log(`lab.json: ${Object.keys(icons).length} icons`);
