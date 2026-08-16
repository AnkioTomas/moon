/* 文件管理页面逻辑（依赖 /js.js 共享函数与 /api/config） */
loadConfig().then(function(config){
    var cur = config.home;
    var hist = [];
    var backBtn = el('back');
    backBtn.onclick = function(){
        if(!hist.length){return}
        load(hist.pop(), true);
    };
    config.shortcuts.forEach(function(s){
        var b=document.createElement('button');b.textContent=s.label;
        b.onclick=function(){load(s.path)};
        el('quick').appendChild(b);
    });
    function load(p, nohist){
        jfetch('/api/list?path='+encodeURIComponent(p)).then(function(d){
            if(!nohist && d.path!=cur){hist.push(cur)}
            cur = d.path;
            backBtn.disabled = hist.length==0;
            el('path').textContent = cur;
            /* 书籍根目录的目录约定只在首页提示，进入其它目录不打扰 */
            el('booktip').style.display = (cur==config.home)?'':'none';
            var tb = el('list');
            tb.innerHTML = '';
            if(d.parent){
                var tr0 = document.createElement('tr');
                tr0.className = 'd';
                tr0.innerHTML = '<td class="n"><a href="#">../</a></td><td></td><td></td><td></td>';
                tr0.firstChild.firstChild.onclick = function(){load(d.parent);return false};
                tb.appendChild(tr0);
            }
            d.entries.forEach(function(e){
                var full = (cur=='/'?'':cur)+'/'+e.name;
                var tr = document.createElement('tr');
                if(e.dir){tr.className='d'}
                var td = document.createElement('td');td.className='n';
                var a = document.createElement('a');
                a.textContent = e.name + (e.dir?'/':'');
                a.href = '#';
                if(e.dir){
                    a.onclick = function(){load(full);return false};
                }else{
                    a.href = '/download?path='+encodeURIComponent(full);
                }
                td.appendChild(a);tr.appendChild(td);
                var s = document.createElement('td');s.className='r';s.textContent = e.dir?'':fmt(e.size);tr.appendChild(s);
                var m = document.createElement('td');m.className='r';m.textContent = fmtT(e.mtime);tr.appendChild(m);
                var op = document.createElement('td');op.className='r';
                var rn = document.createElement('a');rn.className='act rn';rn.textContent='重命名';
                rn.onclick = function(){
                    dialog({title:'重命名 / 移动', msg:full, input:full, ok:'保存'}).then(function(to){
                        if(!to || to==full){return}
                        jfetch('/api/rename?path='+encodeURIComponent(full)+'&to='+encodeURIComponent(to),{method:'POST'}).then(function(){load(cur,true)}).catch(function(e){say('重命名失败: '+e)});
                    });
                };
                var del = document.createElement('a');del.className='act';del.textContent='删除';
                del.onclick = function(){
                    dialog({title:'删除', msg:'删除 '+full+' ？目录将递归删除，不可恢复。', ok:'删除', danger:true}).then(function(yes){
                        if(!yes){return}
                        jfetch('/api/delete?path='+encodeURIComponent(full),{method:'POST'}).then(function(){load(cur,true)}).catch(function(e){say('删除失败: '+e)});
                    });
                };
                if(!e.protected){op.appendChild(rn);op.appendChild(del)}
                tr.appendChild(op);
                tb.appendChild(tr);
            });
            if(!d.entries.length && !d.parent){
                tb.innerHTML = '<tr><td colspan="4" style="color:var(--mut)">空目录</td></tr>';
            }
        }).catch(function(e){say('列表失败: '+e)});
    }
    el('up').onclick = function(){
        var fs = el('file').files;
        if(!fs.length){return}
        var i = 0;
        (function next(){
            if(i >= fs.length){say('全部完成');load(cur,true);return}
            var f = fs[i++];
            say('上传 '+f.name+' ('+fmt(f.size)+')… ');
            jfetch('/upload?dir='+encodeURIComponent(cur)+'&name='+encodeURIComponent(f.name), {method:'PUT', body:f}).then(function(){
                el('log').textContent += '成功\n';
                next();
            }).catch(function(e){el('log').textContent += '失败: '+e+'\n';next()});
        })();
    };
    el('mk').onclick = function(){
        dialog({title:'新建文件夹', input:'', ok:'创建'}).then(function(n){
            if(!n){return}
            var p = (cur=='/'?'':cur)+'/'+n;
            jfetch('/api/mkdir?path='+encodeURIComponent(p),{method:'POST'}).then(function(){load(cur,true)}).catch(function(e){say('新建失败: '+e)});
        });
    };
    load(cur, true);
}).catch(function(e){el('path').textContent = '配置加载失败: '+e});
