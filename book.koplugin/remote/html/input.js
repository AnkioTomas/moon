/* 远程输入 / 共享剪贴板页面逻辑（依赖 /js.js 共享函数）
   - 共享剪贴板：GET/POST /api/clipboard，设备最后复制的文本（阅读划线复制、
     链接复制等都在服务端镜像），随时可拉取/覆盖，与输入框激活无关；
     写入设备时若正好有激活输入框，会同步 setText 进去。
   - 远程输入：GET/POST /api/input，激活输入框才能用，addChars 光标处追加。
   两边都是点击时整段传输；剪贴板轮询跟随设备端新复制（本地编辑中不打断）。 */
var cbtext = el('cbtext');
var cbpush = el('cbpush');
var cbstate = el('cbstate');
var ritext = el('ritext');
var risend = el('risend');
var ristate = el('ristate');
var pulled = ''; // 上次从设备读到的剪贴板文本；本地编辑 ≠ 设备变更，靠它区分

function flash(s){
    cbstate.textContent = s;
    pulled = cbtext.value; // 设备剪贴板已被本次操作改写，别让下一轮轮询闪回
}

/* 共享剪贴板 */
function pollClipboard(){
    jfetch('/api/clipboard').then(function(d){
        var text = d.text || '';
        if(cbtext.value === pulled && text !== cbtext.value){
            cbtext.value = text; // 本地未改动才跟随设备新复制，不打断正在编辑的内容
        }
        pulled = text;
    }).catch(function(){}).then(function(){
        setTimeout(pollClipboard, 2000);
    });
}
cbpush.onclick = function(){
    cbpush.disabled = true;
    jfetch('/api/clipboard', {method:'POST', body:cbtext.value}).then(function(){
        flash('已写入设备 ✓');
    }).catch(function(e){
        cbstate.textContent = '发送失败: ' + e;
    }).then(function(){
        cbpush.disabled = false;
    });
};
el('cbpull').onclick = function(){
    jfetch('/api/clipboard').then(function(d){
        cbtext.value = d.text || '';
        flash('已从设备拉取 ✓');
    }).catch(function(e){
        cbstate.textContent = '拉取失败: ' + e;
    });
};
el('cbclear').onclick = function(){
    cbtext.value = '';
    jfetch('/api/clipboard', {method:'POST', body:''}).then(function(){
        flash('已清空设备剪贴板 ✓');
    }).catch(function(e){
        cbstate.textContent = '清空失败: ' + e;
    });
};
el('cbcopy').onclick = function(){
    if(!navigator.clipboard || !navigator.clipboard.writeText){
        cbstate.textContent = '当前浏览器不支持剪贴板 API（需 HTTPS 或 localhost）';
        return;
    }
    navigator.clipboard.writeText(cbtext.value).then(function(){
        flash('已复制到本机剪贴板 ✓');
    }).catch(function(){
        cbstate.textContent = '复制失败：浏览器拒绝了剪贴板访问';
    });
};

/* 远程输入（光标处追加，语义与旧版一致） */
function pollInput(){
    jfetch('/api/input').then(function(d){
        var active = d.active;
        ritext.disabled = risend.disabled = !active;
        ristate.textContent = active ? '设备输入框已激活，可以发送' : '设备上暂无激活的输入框';
        ristate.className = active ? 'on' : '';
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
pollClipboard();
pollInput();
