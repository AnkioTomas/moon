/* 远程管理共享 JS：文件管理 / 远程输入页面共用（经 /js.js 路由加载） */
function fmt(n){return n==null?'':n>1073741824?(n/1073741824).toFixed(1)+' G':n>1048576?(n/1048576).toFixed(1)+' M':n>1024?(n/1024).toFixed(0)+' K':n+' B'}
function fmtT(t){if(!t)return'';var d=new Date(t*1000);function p(x){return(x<10?'0':'')+x}return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes())}
function el(id){return document.getElementById(id)}
function say(s){el('log').textContent += s + '\n'}
function jfetch(u,opt){
    return fetch(u,opt).then(function(r){
        return r.text().then(function(t){
            var d;
            try{d=JSON.parse(t)}catch(e){throw 'HTTP '+r.status}
            if(!r.ok){throw (d&&d.error)||('HTTP '+r.status)}
            return d;
        });
    });
}
/* 页面配置（root/home/shortcuts 由 /api/config 提供，免模板注入） */
function loadConfig(){
    return jfetch('/api/config');
}
/* 自绘弹窗：prompt / confirm 的替代（原生弹窗在部分浏览器样式突兀） */
function dialog(o){
    var ov = el('ov'), di = el('di'), dk = el('dk');
    el('dt').textContent = o.title||'';
    el('dm').textContent = o.msg||'';
    di.style.display = o.input==null?'none':'';
    di.value = o.input||'';
    dk.textContent = o.ok||'确定';
    dk.className = o.danger?'danger':'primary';
    ov.className = 'on';
    if(o.input!=null){di.focus();di.select()}
    return new Promise(function(res){
        el('dc').onclick = function(){ov.className='';res(null)};
        dk.onclick = function(){ov.className='';res(o.input==null?true:di.value)};
        di.onkeydown = function(e){if(e.key=='Enter'){dk.onclick()}};
    });
}
