/* 远程输入页面逻辑：轮询设备输入框激活状态，激活才可编辑发送
   （不实时传输，点发送整段注入；依赖 /js.js 共享函数） */
var ritext = el('ritext');
var risend = el('risend');
var ristate = el('ristate');
function pollInput(){
    jfetch('/api/input').then(function(d){
        ritext.disabled = !d.active;
        risend.disabled = !d.active;
        ristate.textContent = d.active ? '设备输入框已激活，可以发送' : '设备上暂无激活的输入框';
        ristate.className = d.active ? 'on' : '';
    }).catch(function(){}).then(function(){
        setTimeout(pollInput, 3000);
    });
}
risend.onclick = function(){
    var text = ritext.value;
    if(!text){return}
    risend.disabled = true;
    jfetch('/api/input', {method:'POST', body:text}).then(function(){
        ritext.value = '';
        ristate.textContent = '已发送 ✓';
    }).catch(function(e){
        ristate.textContent = '发送失败: ' + e;
    }).then(function(){
        risend.disabled = false;
    });
};
pollInput();
