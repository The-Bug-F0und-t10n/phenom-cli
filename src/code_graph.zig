const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const symbol_ranker = @import("symbol_ranker.zig");
const workspace_inventory = @import("workspace_inventory.zig");

const max_indexed_files: usize = 512;
const max_file_bytes: usize = 128 * 1024;
const max_symbol_lines: usize = 96;
const max_terms: usize = 24;

pub const Candidate = struct {
    path: []u8,
    symbol: []u8,
    start_line: usize,
    end_line: usize,
    score: i32,
    relation_count: usize,
    direct_symbol_match: bool,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.symbol);
    }
};

pub const Result = struct {
    candidates: std.ArrayList(Candidate),
    indexed_files: usize,
    nodes: usize,
    edges: usize,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |candidate| candidate.deinit(allocator);
        self.candidates.deinit(allocator);
    }
};

const Symbol = struct {
    id: usize,
    path: []u8,
    name: []u8,
    signature: []u8,
    start_line: usize,
    end_line: usize,

    fn deinit(self: Symbol, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        allocator.free(self.signature);
    }
};

const Edge = struct {
    src: usize,
    dst: usize,
    kind: EdgeKind,
};

const EdgeKind = enum {
    calls,
    imports,
};

const Term = struct {
    text: []const u8,
};

const Graph = struct {
    symbols: std.ArrayList(Symbol),
    edges: std.ArrayList(Edge),
    indexed_files: usize,

    fn deinit(self: *Graph, allocator: std.mem.Allocator) void {
        for (self.symbols.items) |symbol| symbol.deinit(allocator);
        self.symbols.deinit(allocator);
        self.edges.deinit(allocator);
    }
};

pub fn rank(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    max_candidates: usize,
) !Result {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);
    try exec(allocator, db,
        \\create table nodes(id integer primary key, kind text not null, path text not null, name text not null, line integer not null, end_line integer not null);
        \\create table edges(kind text not null, src integer not null, dst integer not null);
    );

    var graph = try buildGraph(allocator, io, db);
    defer graph.deinit(allocator);

    var candidates = std.ArrayList(Candidate).empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var terms_buf: [max_terms]Term = undefined;
    const terms = terms_buf[0..extractTerms(query, &terms_buf)];
    for (graph.symbols.items) |symbol| {
        const scored = scoreSymbol(symbol, terms, graph.edges.items);
        if (scored.score == 0) continue;
        try appendCandidate(allocator, &candidates, symbol, scored.score, relationCount(symbol.id, graph.edges.items), scored.direct_symbol_match);
    }

    addImmediateNeighbors(allocator, &candidates, graph.symbols.items, graph.edges.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
    sortCandidates(candidates.items);
    trimCandidates(allocator, &candidates, max_candidates);

    return .{
        .candidates = candidates,
        .indexed_files = graph.indexed_files,
        .nodes = graph.symbols.items.len,
        .edges = graph.edges.items.len,
    };
}

pub fn writeHtml(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8) !void {
    var graph = try buildGraph(allocator, io, null);
    defer graph.deinit(allocator);

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);
    try renderHtml(allocator, &html, graph);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = html.items });
}

fn buildGraph(allocator: std.mem.Allocator, io: std.Io, db: ?*c.sqlite3) !Graph {
    var symbols = std.ArrayList(Symbol).empty;
    errdefer {
        for (symbols.items) |symbol| symbol.deinit(allocator);
        symbols.deinit(allocator);
    }
    var edges = std.ArrayList(Edge).empty;
    errdefer edges.deinit(allocator);

    const indexed = try indexWorkspace(allocator, io, db, &symbols);
    try collectEdges(allocator, io, db, symbols.items, &edges);
    return .{ .symbols = symbols, .edges = edges, .indexed_files = indexed };
}

fn renderHtml(allocator: std.mem.Allocator, out: *std.ArrayList(u8), graph: Graph) !void {
    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Phenom Code Graph</title>
        \\<style>
        \\:root{color-scheme:dark;--bg:#0b0d10;--panel:#15191e;--panel2:#101419;--text:#e6edf3;--muted:#8b949e;--line:#30363d;--soft:#202831;--green:#3fb950;--yellow:#d29922;--blue:#58a6ff;--violet:#bc8cff;--red:#ff7b72}
        \\*{box-sizing:border-box}
        \\body{margin:0;background:var(--bg);color:var(--text);font:13px/1.45 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        \\header{display:flex;gap:16px;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--line);background:var(--panel)}
        \\h1{font-size:15px;margin:0;font-weight:650;letter-spacing:0}
        \\#summary{color:var(--muted);white-space:nowrap}
        \\main{display:grid;grid-template-columns:minmax(0,1fr) 360px;min-height:calc(100vh - 50px)}
        \\#stage{min-width:0;position:relative;background:linear-gradient(#0d1117,#0b0d10)}
        \\#graph{width:100%;height:calc(100vh - 50px);display:block}
        \\aside{border-left:1px solid var(--line);background:var(--panel);padding:14px;overflow:auto}
        \\label{display:block;color:var(--muted);font-size:11px;text-transform:uppercase;margin:12px 0 6px}
        \\input,select{width:100%;border:1px solid var(--line);background:#0d1117;color:var(--text);border-radius:6px;padding:8px}
        \\button{border:1px solid var(--line);background:#21262d;color:var(--text);border-radius:6px;padding:8px 10px;cursor:pointer}
        \\button:hover{border-color:var(--blue)}
        \\.row{display:grid;grid-template-columns:1fr 1fr;gap:8px}
        \\.legend{display:flex;gap:12px;flex-wrap:wrap;color:var(--muted);font-size:12px;margin:10px 0}
        \\.key{display:inline-flex;gap:6px;align-items:center}
        \\.swatch{width:14px;height:3px;border-radius:2px;display:inline-block;background:var(--line)}
        \\.swatch.calls{background:var(--blue)}
        \\.swatch.imports{background:var(--yellow)}
        \\dl{display:grid;grid-template-columns:1fr auto;gap:4px 10px;margin:12px 0}
        \\dt{color:var(--muted)}
        \\dd{margin:0}
        \\pre{white-space:pre-wrap;word-break:break-word;background:#0d1117;border:1px solid var(--line);border-radius:6px;padding:10px;min-height:160px}
        \\.lane{fill:#0f141a;stroke:#212a33;stroke-width:1}
        \\.lane:nth-child(odd){fill:#10171f}
        \\.lane-label{fill:#8b949e;font-size:12px;font-weight:650}
        \\.lane-sub{fill:#6e7681;font-size:10px}
        \\.axis{stroke:#252d37;stroke-width:1}
        \\.edge{fill:none;stroke:#38404a;stroke-width:1.4;opacity:.44}
        \\.edge.calls{stroke:var(--blue)}
        \\.edge.imports{stroke:var(--yellow);stroke-dasharray:5 4}
        \\.edge.dim{opacity:.08}
        \\.edge.focus{opacity:1;stroke-width:2.8}
        \\.node{stroke:#0d1117;stroke-width:1.6;cursor:pointer}
        \\.node.dim{opacity:.22}
        \\.node.focus{stroke:#fff;stroke-width:3.2}
        \\.node.hit{stroke:var(--red);stroke-width:3}
        \\.label{fill:#d0d7de;font-size:11px;paint-order:stroke;stroke:#0d1117;stroke-width:3;pointer-events:none}
        \\.label.dim{opacity:.24}
        \\.hint{position:absolute;left:14px;bottom:12px;color:#8b949e;background:rgba(13,17,23,.78);border:1px solid var(--line);border-radius:6px;padding:6px 8px}
        \\.zoom{position:absolute;left:14px;top:14px;display:flex;gap:6px;background:rgba(13,17,23,.78);border:1px solid var(--line);border-radius:6px;padding:6px}
        \\.zoom button{padding:4px 8px}
        \\.zoom span{color:var(--muted);min-width:44px;text-align:center;align-self:center}
        \\@media(max-width:900px){main{grid-template-columns:1fr}aside{border-left:0;border-top:1px solid var(--line)}#graph{height:68vh}}
        \\</style>
        \\</head>
        \\<body>
        \\<header><h1>Phenom Code Graph</h1><div id="summary"></div></header>
        \\<main><section id="stage"><svg id="graph" role="img" aria-label="Code graph"></svg><div class="zoom"><button id="zoomOut">-</button><button id="zoomIn">+</button><button id="zoomFit">fit</button><span id="zoomPct">100%</span></div><div class="hint">Wheel zooms. Drag pans. Lane = file. X axis = source line. Solid = calls. Dashed = imports.</div></section><aside>
        \\<label for="q">Search</label><input id="q" autocomplete="off" placeholder="symbol or path">
        \\<div class="row"><div><label for="edgeKind">Edges</label><select id="edgeKind"><option value="all">all</option><option value="calls">calls</option><option value="imports">imports</option></select></div><div><label for="limit">Nodes</label><select id="limit"><option value="120">top 120</option><option value="240">top 240</option><option value="0">all</option></select></div></div>
        \\<label for="minDegree">Minimum degree</label><input id="minDegree" type="number" min="0" value="1">
        \\<p><button id="fit">Fit graph</button> <button id="clear">Clear focus</button></p>
        \\<div class="legend"><span class="key"><span class="swatch calls"></span>calls</span><span class="key"><span class="swatch imports"></span>imports</span></div>
        \\<dl><dt>Visible nodes</dt><dd id="nodesCount"></dd><dt>Visible edges</dt><dd id="edgesCount"></dd><dt>Files</dt><dd id="filesCount"></dd><dt>Focused</dt><dd id="focusCount"></dd></dl>
        \\<pre id="details">Click a node.</pre>
        \\</aside></main>
        \\<script>
        \\const graphData =
    );
    try appendGraphJson(allocator, out, graph);
    try out.appendSlice(allocator,
        \\;
        \\const svg=document.getElementById("graph");
        \\const summary=document.getElementById("summary");
        \\const q=document.getElementById("q");
        \\const edgeKind=document.getElementById("edgeKind");
        \\const limit=document.getElementById("limit");
        \\const minDegree=document.getElementById("minDegree");
        \\const details=document.getElementById("details");
        \\const zoomPct=document.getElementById("zoomPct");
        \\let selected=null;
        \\let baseBox={x:0,y:0,w:1000,h:600},viewBox=null,isPanning=false,panStart=null;
        \\const nodesById=new Map(graphData.nodes.map(n=>[n.id,n]));
        \\const outEdges=new Map(),inEdges=new Map(),fileMaxLine=new Map();
        \\for(const n of graphData.nodes){fileMaxLine.set(n.path,Math.max(fileMaxLine.get(n.path)||1,n.endLine||n.line||1))}
        \\for(const e of graphData.edges){if(!outEdges.has(e.source))outEdges.set(e.source,[]);if(!inEdges.has(e.target))inEdges.set(e.target,[]);outEdges.get(e.source).push(e);inEdges.get(e.target).push(e)}
        \\function fileName(path){const i=path.lastIndexOf("/");return i>=0?path.slice(i+1):path}
        \\function dirName(path){const i=path.lastIndexOf("/");return i>=0?path.slice(0,i):"."}
        \\function match(n,term){return !term||n.name.toLowerCase().includes(term)||n.path.toLowerCase().includes(term)}
        \\function filtered(){const term=q.value.trim().toLowerCase();const min=Number(minDegree.value)||0;const kind=edgeKind.value;const cap=Number(limit.value)||0;let nodes=graphData.nodes.filter(n=>n.degree>=min&&match(n,term));nodes.sort((a,b)=>term?((a.path+a.name).localeCompare(b.path+b.name)):(b.degree-a.degree||a.path.localeCompare(b.path)||a.line-b.line));if(cap>0&&nodes.length>cap)nodes=nodes.slice(0,cap);nodes.sort((a,b)=>a.path.localeCompare(b.path)||a.line-b.line||a.name.localeCompare(b.name));const keep=new Set(nodes.map(n=>n.id));const edges=graphData.edges.filter(e=>(kind==="all"||e.kind===kind)&&keep.has(e.source)&&keep.has(e.target));return{nodes,edges,keep,term}}
        \\function color(n){if(n.path.endsWith(".zig"))return"#3fb950";if(n.path.endsWith(".ts")||n.path.endsWith(".js"))return"#58a6ff";if(n.path.endsWith(".md"))return"#d29922";return"#bc8cff"}
        \\function focusedSet(){if(selected==null)return null;const set=new Set([selected]);for(const e of outEdges.get(selected)||[])set.add(e.target);for(const e of inEdges.get(selected)||[])set.add(e.source);return set}
        \\function place(view){const paths=[...new Set(view.nodes.map(n=>n.path))];const laneH=76,left=220,right=90,top=52,w=Math.max(980,svg.clientWidth*1.8);const lanes=new Map();paths.forEach((path,i)=>lanes.set(path,{path,y:top+i*laneH,h:laneH-16}));for(const n of view.nodes){const lane=lanes.get(n.path);const max=fileMaxLine.get(n.path)||Math.max(1,n.endLine||n.line||1);const t=Math.max(0,Math.min(1,(n.line||1)/max));n._x=left+t*(w-left-right);n._y=lane.y+Math.min(lane.h-12,14+((n.line*17+n.id*7)%(lane.h-24)));}return{lanes,w,h:top+paths.length*laneH+40,left,right}}
        \\function add(tag,attrs,parent=svg){const el=document.createElementNS(svg.namespaceURI,tag);for(const [k,v] of Object.entries(attrs||{}))el.setAttribute(k,v);parent.appendChild(el);return el}
        \\function pathFor(a,b,kind){const dx=Math.max(70,Math.abs(b._x-a._x)*.45);const bend=kind==="imports"?120:40;return `M${a._x},${a._y} C${a._x+dx},${a._y+bend} ${b._x-dx},${b._y-bend} ${b._x},${b._y}`}
        \\function nodeText(n){const outs=(outEdges.get(n.id)||[]).map(e=>nodesById.get(e.target)).filter(Boolean).slice(0,12).map(x=>"  -> "+x.name+"  "+x.path).join("\\n");const ins=(inEdges.get(n.id)||[]).map(e=>nodesById.get(e.source)).filter(Boolean).slice(0,12).map(x=>"  <- "+x.name+"  "+x.path).join("\\n");return n.name+"\\n"+n.path+":"+n.line+"-"+n.endLine+"\\ndegree "+n.degree+"\\n\\nOutgoing\\n"+(outs||"  none")+"\\n\\nIncoming\\n"+(ins||"  none")}
        \\function render(resetView=false){const view=filtered();const focus=focusedSet();const layout=place(view);svg.textContent="";const defs=add("defs",{});const marker=add("marker",{id:"arrow",viewBox:"0 0 10 10",refX:"9",refY:"5",markerWidth:"6",markerHeight:"6",orient:"auto-start-reverse"},defs);add("path",{d:"M0,0 L10,5 L0,10 z",fill:"#6e7681"},marker);const lanes=[...layout.lanes.values()];for(const lane of lanes){add("rect",{class:"lane",x:12,y:lane.y-12,width:layout.w-24,height:lane.h+16,rx:6});add("line",{class:"axis",x1:layout.left,y1:lane.y+lane.h,x2:layout.w-layout.right,y2:lane.y+lane.h});add("text",{class:"lane-label",x:24,y:lane.y+8}).textContent=fileName(lane.path);add("text",{class:"lane-sub",x:24,y:lane.y+24}).textContent=dirName(lane.path)}for(const e of view.edges){const a=nodesById.get(e.source),b=nodesById.get(e.target);const inFocus=!focus||focus.has(e.source)&&focus.has(e.target);const cls="edge "+e.kind+(inFocus?"":" dim")+(selected!=null&&(e.source===selected||e.target===selected)?" focus":"");add("path",{class:cls,d:pathFor(a,b,e.kind),"marker-end":"url(#arrow)"})}for(const n of view.nodes){const inFocus=!focus||focus.has(n.id);const isHit=view.term&&match(n,view.term);const cls="node"+(inFocus?"":" dim")+(selected===n.id?" focus":"")+(isHit?" hit":"");const r=Math.min(18,5+n.degree);const c=add("circle",{class:cls,cx:n._x,cy:n._y,r,fill:color(n)});c.addEventListener("click",()=>{selected=n.id;details.textContent=nodeText(n);render()});if(n.degree>2||view.nodes.length<140||isHit){const l=add("text",{class:"label"+(inFocus?"":" dim"),x:n._x+r+4,y:n._y+4});l.textContent=n.name}}document.getElementById("nodesCount").textContent=view.nodes.length+"/"+graphData.nodes.length;document.getElementById("edgesCount").textContent=view.edges.length+"/"+graphData.edges.length;document.getElementById("focusCount").textContent=selected==null?"none":(nodesById.get(selected)?.name||"missing");setBase(layout);if(resetView||!viewBox)viewBox={...baseBox};applyViewBox()}
        \\function applyViewBox(){svg.setAttribute("viewBox",[viewBox.x,viewBox.y,viewBox.w,viewBox.h].join(" "));zoomPct.textContent=Math.round((baseBox.w/viewBox.w)*100)+"%"}
        \\function setBase(layout){const pad=28;baseBox={x:0,y:0,w:Math.max(300,layout?.w||1000)+pad,h:Math.max(200,layout?.h||600)}}
        \\function fit(layout){setBase(layout);viewBox={...baseBox};applyViewBox()}
        \\function zoomAt(factor,cx,cy){const pt=svg.createSVGPoint();pt.x=cx;pt.y=cy;const p=pt.matrixTransform(svg.getScreenCTM().inverse());const nw=Math.max(80,Math.min(baseBox.w*6,viewBox.w*factor));const nh=Math.max(80,Math.min(baseBox.h*6,viewBox.h*factor));const rx=(p.x-viewBox.x)/viewBox.w,ry=(p.y-viewBox.y)/viewBox.h;viewBox={x:p.x-rx*nw,y:p.y-ry*nh,w:nw,h:nh};applyViewBox()}
        \\function clientPoint(ev){const pt=svg.createSVGPoint();pt.x=ev.clientX;pt.y=ev.clientY;return pt.matrixTransform(svg.getScreenCTM().inverse())}
        \\svg.addEventListener("wheel",ev=>{ev.preventDefault();zoomAt(ev.deltaY<0?.82:1.22,ev.clientX,ev.clientY)},{passive:false});
        \\svg.addEventListener("pointerdown",ev=>{if(ev.target.classList?.contains("node"))return;isPanning=true;panStart={client:{x:ev.clientX,y:ev.clientY},box:{...viewBox}};svg.setPointerCapture(ev.pointerId)});
        \\svg.addEventListener("pointermove",ev=>{if(!isPanning)return;const a=clientPoint({clientX:panStart.client.x,clientY:panStart.client.y}),b=clientPoint(ev);viewBox={...panStart.box,x:panStart.box.x+(a.x-b.x),y:panStart.box.y+(a.y-b.y)};applyViewBox()});
        \\svg.addEventListener("pointerup",ev=>{isPanning=false;try{svg.releasePointerCapture(ev.pointerId)}catch{}});
        \\summary.textContent=graphData.nodes.length+" nodes, "+graphData.edges.length+" edges";document.getElementById("filesCount").textContent=graphData.indexedFiles;q.addEventListener("input",()=>{selected=null;render(true)});edgeKind.addEventListener("change",()=>render(true));limit.addEventListener("change",()=>{selected=null;render(true)});minDegree.addEventListener("input",()=>{selected=null;render(true)});document.getElementById("fit").addEventListener("click",()=>render(true));document.getElementById("zoomFit").addEventListener("click",()=>render(true));document.getElementById("zoomIn").addEventListener("click",()=>zoomAt(.82,svg.clientWidth/2,svg.clientHeight/2));document.getElementById("zoomOut").addEventListener("click",()=>zoomAt(1.22,svg.clientWidth/2,svg.clientHeight/2));document.getElementById("clear").addEventListener("click",()=>{selected=null;details.textContent="Click a node.";render()});render(true);
        \\</script>
        \\</body>
        \\</html>
        \\
    );
}

fn appendGraphJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), graph: Graph) !void {
    try out.appendSlice(allocator, "{\"indexedFiles\":");
    try appendFmt(allocator, out, "{}", .{graph.indexed_files});
    try out.appendSlice(allocator, ",\"nodes\":[");
    for (graph.symbols.items, 0..) |symbol, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{\"id\":");
        try appendFmt(allocator, out, "{}", .{symbol.id});
        try out.appendSlice(allocator, ",\"path\":");
        try appendJsonString(allocator, out, symbol.path);
        try out.appendSlice(allocator, ",\"name\":");
        try appendJsonString(allocator, out, symbol.name);
        try out.appendSlice(allocator, ",\"line\":");
        try appendFmt(allocator, out, "{}", .{symbol.start_line});
        try out.appendSlice(allocator, ",\"endLine\":");
        try appendFmt(allocator, out, "{}", .{symbol.end_line});
        try out.appendSlice(allocator, ",\"degree\":");
        try appendFmt(allocator, out, "{}", .{relationCount(symbol.id, graph.edges.items)});
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "],\"edges\":[");
    for (graph.edges.items, 0..) |edge, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try appendFmt(allocator, out, "{{\"source\":{},\"target\":{},\"kind\":", .{ edge.src, edge.dst });
        try appendJsonString(allocator, out, @tagName(edge.kind));
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]}");
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.appendSlice(allocator, "\"");
    for (text) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 32 or byte >= 128) {
                    try appendJsonByteEscape(allocator, out, byte);
                } else {
                    try out.append(allocator, byte);
                }
            },
        }
    }
    try out.appendSlice(allocator, "\"");
}

fn appendJsonByteEscape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) !void {
    const hex = "0123456789abcdef";
    const escaped = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };
    try out.appendSlice(allocator, &escaped);
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn indexWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*c.sqlite3,
    symbols: *std.ArrayList(Symbol),
) !usize {
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var inventory = try workspace_inventory.collect(allocator, io, max_indexed_files * 4);
    defer inventory.deinit(allocator);

    var indexed: usize = 0;
    for (inventory.paths.items) |path| {
        if (indexed >= max_indexed_files) break;
        const content = cwd.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch continue;
        defer allocator.free(content);
        if (!workspace_inventory.isTextBytes(content)) continue;
        indexed += 1;
        try collectFileSymbols(allocator, db, symbols, path, content);
    }
    return indexed;
}

fn collectFileSymbols(
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,
    symbols: *std.ArrayList(Symbol),
    path: []const u8,
    content: []const u8,
) !void {
    var offset: usize = 0;
    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        defer {
            offset += line.len + 1;
            line_no += 1;
        }
        const symbol = parseSymbolLine(path, line, line_no, content[offset..]) orelse continue;
        const id = symbols.items.len + 1;
        var owned = Symbol{
            .id = id,
            .path = try allocator.dupe(u8, symbol.path),
            .name = try allocator.dupe(u8, symbol.name),
            .signature = try allocator.dupe(u8, symbol.signature),
            .start_line = symbol.start_line,
            .end_line = symbol.end_line,
        };
        errdefer owned.deinit(allocator);
        try insertNode(allocator, db, owned);
        try symbols.append(allocator, owned);
    }
}

const ParsedSymbol = struct {
    path: []const u8,
    name: []const u8,
    signature: []const u8,
    start_line: usize,
    end_line: usize,
};

fn parseSymbolLine(path: []const u8, line: []const u8, line_no: usize, tail: []const u8) ?ParsedSymbol {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var text = stripPrefix(trimmed, "pub ") orelse trimmed;
    text = stripPrefix(text, "export ") orelse text;
    if (stripPrefix(text, "fn ")) |rest| return parsed(path, takeIdentifier(rest), trimmed, line_no, tail);
    if (stripPrefix(text, "const ")) |rest| {
        const name = takeIdentifier(rest);
        if (name.len == 0) return null;
        const after_name = std.mem.trim(u8, rest[name.len..], " \t");
        if (std.mem.startsWith(u8, after_name, "= @import(") or std.mem.startsWith(u8, after_name, "= @cImport(")) return null;
        return parsed(path, name, trimmed, line_no, tail);
    }
    if (stripPrefix(text, "function ")) |rest| return parsed(path, takeIdentifier(rest), trimmed, line_no, tail);
    if (stripPrefix(text, "class ")) |rest| return parsed(path, takeIdentifier(rest), trimmed, line_no, tail);
    return null;
}

fn parsed(path: []const u8, name: []const u8, signature: []const u8, line_no: usize, tail: []const u8) ?ParsedSymbol {
    if (name.len == 0) return null;
    return .{ .path = path, .name = name, .signature = signature, .start_line = line_no, .end_line = estimateEndLine(line_no, tail) };
}

fn collectEdges(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?*c.sqlite3,
    symbols: []const Symbol,
    edges: *std.ArrayList(Edge),
) !void {
    const root = std.Io.Dir.cwd();
    var cwd = try root.openDir(io, ".", .{});
    defer cwd.close(io);
    var current_path: []const u8 = "";
    var content: []u8 = "";
    defer if (content.len > 0) allocator.free(content);
    var import_paths = std.ArrayList([]u8).empty;
    defer {
        for (import_paths.items) |path| allocator.free(path);
        import_paths.deinit(allocator);
    }

    for (symbols) |src| {
        if (!std.mem.eql(u8, current_path, src.path)) {
            if (content.len > 0) allocator.free(content);
            for (import_paths.items) |path| allocator.free(path);
            import_paths.clearRetainingCapacity();
            content = cwd.readFileAlloc(io, src.path, allocator, .limited(max_file_bytes)) catch {
                content = "";
                current_path = src.path;
                continue;
            };
            current_path = src.path;
            try collectImportTargets(allocator, src.path, content, &import_paths);
        }
        const body = sliceLines(content, src.start_line, src.end_line);
        if (firstSymbolForPath(symbols, src.path)) |module_symbol| {
            if (module_symbol.id == src.id) {
                for (import_paths.items) |target_path| {
                    const imported = firstSymbolForPath(symbols, target_path) orelse continue;
                    try appendEdge(allocator, db, edges, .{ .src = src.id, .dst = imported.id, .kind = .imports });
                }
            }
        }
        for (symbols) |dst| {
            if (src.id == dst.id) continue;
            if (!std.mem.eql(u8, src.path, dst.path)) continue;
            if (containsCall(body, dst.name)) {
                try appendEdge(allocator, db, edges, .{ .src = src.id, .dst = dst.id, .kind = .calls });
            }
        }
    }
}

fn collectImportTargets(allocator: std.mem.Allocator, current_path: []const u8, content: []const u8, out: *std.ArrayList([]u8)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, "@import(\"")) |idx| {
            const path_start = idx + "@import(\"".len;
            const path_end = std.mem.indexOfScalarPos(u8, line, path_start, '"') orelse break;
            const raw = line[path_start..path_end];
            start = path_end + 1;
            if (!std.mem.endsWith(u8, raw, ".zig")) continue;
            const target = try resolveImportPath(allocator, current_path, raw);
            errdefer allocator.free(target);
            if (!workspace_inventory.isWorkspacePath(target)) {
                allocator.free(target);
                continue;
            }
            if (containsOwnedPath(out.items, target)) {
                allocator.free(target);
                continue;
            }
            try out.append(allocator, target);
        }
    }
}

fn resolveImportPath(allocator: std.mem.Allocator, current_path: []const u8, raw: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, raw, "./") or std.mem.startsWith(u8, raw, "../")) {
        const slash = std.mem.lastIndexOfScalar(u8, current_path, '/') orelse return normalizeRelativePath(allocator, raw);
        const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path[0..slash], raw });
        defer allocator.free(joined);
        return normalizeRelativePath(allocator, joined);
    }
    if (std.mem.indexOfScalar(u8, raw, '/') != null) return allocator.dupe(u8, raw);
    const slash = std.mem.lastIndexOfScalar(u8, current_path, '/') orelse return allocator.dupe(u8, raw);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path[0..slash], raw });
}

fn normalizeRelativePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return allocator.dupe(u8, path);
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    return std.mem.join(allocator, "/", parts.items);
}

fn containsOwnedPath(paths: []const []u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

fn appendEdge(allocator: std.mem.Allocator, db: ?*c.sqlite3, edges: *std.ArrayList(Edge), edge: Edge) !void {
    for (edges.items) |existing| {
        if (existing.src == edge.src and existing.dst == edge.dst and existing.kind == edge.kind) return;
    }
    try insertEdge(allocator, db, edge);
    try edges.append(allocator, edge);
}

fn insertNode(allocator: std.mem.Allocator, db: ?*c.sqlite3, symbol: Symbol) !void {
    const handle = db orelse return;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "insert into nodes(id, kind, path, name, line, end_line) values (?1, 'symbol', ?2, ?3, ?4, ?5)";
    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    if (c.sqlite3_prepare_v2(handle, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_bind_int64(stmt, 1, @as(i64, @intCast(symbol.id))) != c.SQLITE_OK) return error.SqliteBindFailed;
    try bindText(allocator, stmt, 2, symbol.path);
    try bindText(allocator, stmt, 3, symbol.name);
    if (c.sqlite3_bind_int64(stmt, 4, @as(i64, @intCast(symbol.start_line))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_bind_int64(stmt, 5, @as(i64, @intCast(symbol.end_line))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn insertEdge(allocator: std.mem.Allocator, db: ?*c.sqlite3, edge: Edge) !void {
    const handle = db orelse return;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "insert into edges(kind, src, dst) values (?1, ?2, ?3)";
    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    if (c.sqlite3_prepare_v2(handle, z_sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(allocator, stmt, 1, @tagName(edge.kind));
    if (c.sqlite3_bind_int64(stmt, 2, @as(i64, @intCast(edge.src))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_bind_int64(stmt, 3, @as(i64, @intCast(edge.dst))) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn bindText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    _ = allocator;
    if (c.sqlite3_bind_text(stmt, index, text.ptr, @as(c_int, @intCast(text.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn exec(allocator: std.mem.Allocator, db: ?*c.sqlite3, sql: []const u8) !void {
    const z_sql = try allocator.dupeZ(u8, sql);
    defer allocator.free(z_sql);
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(db, z_sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return error.SqliteExecFailed;
    }
}

const SymbolScore = struct {
    score: i32,
    direct_symbol_match: bool,
};

fn scoreSymbol(symbol: Symbol, terms: []const Term, edges: []const Edge) SymbolScore {
    var score: i32 = 0;
    var direct_symbol_match = false;
    for (terms, 0..) |term, index| {
        const weight: i32 = if (index < 3) 2 else 1;
        if (std.ascii.eqlIgnoreCase(symbol.name, term.text)) {
            direct_symbol_match = true;
            score += 180 * weight;
        }
        if (containsIgnoreCase(symbol.name, term.text)) {
            direct_symbol_match = true;
            score += 90 * weight;
        }
        if (containsIgnoreCase(symbol.path, term.text)) score += 52 * weight;
        const symbol_token_score = symbol_ranker.tokenizedIdentifierMatchScore(symbol.name, term.text, 20, 5);
        if (symbol_token_score > 0) direct_symbol_match = true;
        score += @as(i32, @intCast(symbol_token_score)) * weight;
        score += @as(i32, @intCast(symbol_ranker.tokenizedIdentifierMatchScore(symbol.path, term.text, 8, 2))) * weight;
    }
    if (score == 0) return .{ .score = 0, .direct_symbol_match = false };
    if (direct_symbol_match) {
        score += 480;
        score += @as(i32, @intCast(@min(relationCount(symbol.id, edges) * 8, 64)));
    } else {
        score = @divTrunc(score, 2);
    }
    return .{ .score = score, .direct_symbol_match = direct_symbol_match };
}

fn addImmediateNeighbors(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    symbols: []const Symbol,
    edges: []const Edge,
) !void {
    const original_len = candidates.items.len;
    var index: usize = 0;
    while (index < original_len) : (index += 1) {
        const candidate = candidates.items[index];
        const seed = symbolByPathAndName(symbols, candidate.path, candidate.symbol) orelse continue;
        for (edges) |edge| {
            const neighbor_id = if (edge.src == seed.id) edge.dst else if (edge.dst == seed.id) edge.src else continue;
            const neighbor = symbolById(symbols, neighbor_id) orelse continue;
            try appendCandidate(allocator, candidates, neighbor, @max(@as(i32, 40), @divTrunc(candidate.score, 2)), relationCount(neighbor.id, edges), false);
        }
    }
}

fn appendCandidate(allocator: std.mem.Allocator, out: *std.ArrayList(Candidate), symbol: Symbol, score: i32, relations: usize, direct_symbol_match: bool) !void {
    for (out.items) |*existing| {
        if (!std.mem.eql(u8, existing.path, symbol.path) or !std.mem.eql(u8, existing.symbol, symbol.name)) continue;
        existing.score = @max(existing.score, score);
        existing.relation_count = @max(existing.relation_count, relations);
        existing.direct_symbol_match = existing.direct_symbol_match or direct_symbol_match;
        return;
    }
    try out.append(allocator, .{
        .path = try allocator.dupe(u8, symbol.path),
        .symbol = try allocator.dupe(u8, symbol.name),
        .start_line = symbol.start_line,
        .end_line = symbol.end_line,
        .score = score,
        .relation_count = relations,
        .direct_symbol_match = direct_symbol_match,
    });
}

fn extractTerms(query: []const u8, out: []Term) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n\"'`()[]{}<>:;,.!?/\\|");
    while (it.next()) |raw| {
        const term = std.mem.trim(u8, raw, "-_*");
        if (term.len < 3 or count >= out.len) continue;
        out[count] = .{ .text = term };
        count += 1;
    }
    return count;
}

fn relationCount(id: usize, edges: []const Edge) usize {
    var count: usize = 0;
    for (edges) |edge| {
        if (edge.src == id or edge.dst == id) count += 1;
    }
    return count;
}

fn symbolById(symbols: []const Symbol, id: usize) ?Symbol {
    for (symbols) |symbol| {
        if (symbol.id == id) return symbol;
    }
    return null;
}

fn firstSymbolForPath(symbols: []const Symbol, path: []const u8) ?Symbol {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.path, path)) return symbol;
    }
    return null;
}

fn symbolByPathAndName(symbols: []const Symbol, path: []const u8, name: []const u8) ?Symbol {
    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.path, path) and std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn containsCall(body: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, body, start, name)) |idx| {
        const after = idx + name.len;
        if (after < body.len and body[after] == '(' and (idx == 0 or !isIdentByte(body[idx - 1]))) return true;
        start = after;
    }
    return false;
}

fn sliceLines(content: []const u8, start_line: usize, end_line: usize) []const u8 {
    var line_no: usize = 1;
    var start: usize = 0;
    var end: usize = content.len;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (line_no == start_line) {
            start = i;
            break;
        }
        if (content[i] == '\n') line_no += 1;
    }
    while (i < content.len) : (i += 1) {
        if (line_no > end_line) {
            end = i;
            break;
        }
        if (content[i] == '\n') line_no += 1;
    }
    return content[start..end];
}

fn sortCandidates(candidates: []Candidate) void {
    std.mem.sort(Candidate, candidates, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.relation_count != b.relation_count) return a.relation_count > b.relation_count;
            if (!std.mem.eql(u8, a.path, b.path)) return std.mem.lessThan(u8, a.path, b.path);
            return a.start_line < b.start_line;
        }
    }.lessThan);
}

fn trimCandidates(allocator: std.mem.Allocator, candidates: *std.ArrayList(Candidate), max: usize) void {
    while (candidates.items.len > max) {
        const removed = candidates.pop().?;
        removed.deinit(allocator);
    }
}

fn estimateEndLine(start_line: usize, tail: []const u8) usize {
    var line: usize = start_line;
    var seen_open = false;
    var depth: isize = 0;
    for (tail) |byte| {
        if (byte == '\n') line += 1;
        if (byte == '{') {
            seen_open = true;
            depth += 1;
        } else if (byte == '}') {
            depth -= 1;
            if (seen_open and depth <= 0) return @min(line, start_line + max_symbol_lines - 1);
        }
        if (line >= start_line + max_symbol_lines - 1) return line;
    }
    return @min(line, start_line + max_symbol_lines - 1);
}

fn stripPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

fn takeIdentifier(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and isIdentByte(text[end])) : (end += 1) {}
    return text[0..end];
}

fn isIdentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "caveman graph ranks symbols and saves relations in sqlite" {
    var result = try rank(std.testing.allocator, std.testing.io, "collect evidence candidates execute", 16);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.indexed_files > 0);
    try std.testing.expect(result.nodes > 0);
    try std.testing.expect(result.edges > 0);
    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expect(hasCandidate(result.candidates.items, "src/collect_evidence.zig", "executeCandidates"));
}

test "caveman graph keeps direct symbol match above structural neighbors" {
    var result = try rank(std.testing.allocator, std.testing.io, "executeCandidates", 6);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.candidates.items.len > 0);
    try std.testing.expectEqualStrings("src/collect_evidence.zig", result.candidates.items[0].path);
    try std.testing.expectEqualStrings("executeCandidates", result.candidates.items[0].symbol);
}

test "caveman graph resolves local zig imports" {
    var imports = std.ArrayList([]u8).empty;
    defer {
        for (imports.items) |path| std.testing.allocator.free(path);
        imports.deinit(std.testing.allocator);
    }

    try collectImportTargets(std.testing.allocator, "src/main.zig", "const audit = @import(\"audit.zig\");\nconst http = @import(\"./http.zig\");\nconst cfg = @import(\"../config.zig\");\nconst std = @import(\"std\");\n", &imports);
    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    try std.testing.expectEqualStrings("src/audit.zig", imports.items[0]);
    try std.testing.expectEqualStrings("src/http.zig", imports.items[1]);
    try std.testing.expectEqualStrings("config.zig", imports.items[2]);
}

test "caveman graph writes standalone local html" {
    const path = ".phenom-code-graph-test.html";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try writeHtml(std.testing.allocator, std.testing.io, path);
    const html = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<!doctype html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "const graphData =") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\"nodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\"edges\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "src/code_graph.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Lane = file") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Clear focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "function place(view)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "marker-end") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"zoomIn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "addEventListener(\"wheel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "function zoomAt") != null);
}

fn hasCandidate(candidates: []const Candidate, path: []const u8, symbol: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.path, path) and std.mem.eql(u8, candidate.symbol, symbol)) return true;
    }
    return false;
}
