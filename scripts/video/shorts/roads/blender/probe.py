# note-road look probe -- Blender 5.2.1 LTS, headless.
#   Blender -b -noaudio -P probe.py -- --engine EEVEE --frames 13,25,33 --out /abs/dir
#   Blender -b -noaudio -P probe.py -- --engine CYCLES --anim --out /abs/dir
import bpy, bmesh, sys, os, math, time, json
from mathutils import Vector

# ---------------------------------------------------------------- args
argv = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
def arg(name, default=None):
    return argv[argv.index(name)+1] if name in argv else default
ENGINE   = arg('--engine', 'EEVEE').upper()
OUT      = arg('--out', '/tmp/roadprobe')
TAG      = arg('--tag', 'shot')
FRAMES   = [int(x) for x in arg('--frames', '').split(',') if x.strip()]
ANIM     = '--anim' in argv
DISK_ROUGH = float(arg('--disk-rough', '0.30'))
DECAY_T    = float(arg('--decay', '0.85'))     # seconds from strike to EXACT black
SAMPLES    = int(arg('--samples', '128'))
RESX, RESY = int(arg('--resx', '1920')), int(arg('--resy', '1080'))
os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------- score
FPS   = 24
DUR   = 8.0
V     = 2.0                       # road units per second
NFR   = int(DUR*FPS)
LANE_X = [-2.0, -1.0, 0.0, 1.0]   # 4 pitch voices
PERC_X = 2.0
CHORDS = [(1.00, [0,1,2]), (2.40, [0,2,3]), (3.80, [1,2,3]),
          (5.20, [0,1,3]), (6.60, [0,1,2,3])]
PERC   = [0.70, 1.80, 3.10, 4.40, 5.70, 7.00]
ATTACK = 0.06
def t_of(f): return (f-1)/FPS

def heat(t, t0):
    """0 before strike, 1 at peak, EXACTLY 0.0 at and after t0+DECAY_T."""
    d = t - t0
    if d < 0.0: return 0.0
    if d < ATTACK: return d/ATTACK
    u = (d-ATTACK)/DECAY_T
    if u >= 1.0: return 0.0
    return (1.0-u)**2.2

# ---------------------------------------------------------------- scene
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.frame_start, sc.frame_end = 1, NFR
sc.render.fps = FPS
sc.render.resolution_x, sc.render.resolution_y = RESX, RESY
sc.render.resolution_percentage = 100
sc.render.image_settings.file_format = 'PNG'
sc.view_settings.view_transform = 'AgX'

def mat(name):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes): nt.nodes.remove(n)
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    return m, nt, out

def link(nt,a,ao,b,bi): nt.links.new(a.outputs[ao], b.inputs[bi])

# ---- road material: paper/asphalt fibre grain
road_mat, nt, out = mat('road')
bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled'); bsdf.location=(-200,0)
bsdf.inputs['Base Color'].default_value = (0.052,0.050,0.047,1)
link(nt,bsdf,'BSDF',out,'Surface')
n1 = nt.nodes.new('ShaderNodeTexNoise'); n1.location=(-900,-300)
n1.inputs['Scale'].default_value=300.0; n1.inputs['Detail'].default_value=12.0
n1.inputs['Roughness'].default_value=0.75
bump = nt.nodes.new('ShaderNodeBump'); bump.location=(-500,-300)
bump.inputs['Strength'].default_value=0.22; bump.inputs['Distance'].default_value=0.004
link(nt,n1,'Fac',bump,'Height'); link(nt,bump,'Normal',bsdf,'Normal')
n2 = nt.nodes.new('ShaderNodeTexNoise'); n2.location=(-900,120)
n2.inputs['Scale'].default_value=55.0; n2.inputs['Detail'].default_value=6.0
rr = nt.nodes.new('ShaderNodeMapRange'); rr.location=(-560,120)
rr.inputs['To Min'].default_value=0.68; rr.inputs['To Max'].default_value=0.95
link(nt,n2,'Fac',rr,'Value'); link(nt,rr,'Result',bsdf,'Roughness')
# faint fibre streaks in colour
n3 = nt.nodes.new('ShaderNodeTexNoise'); n3.location=(-900,340)
n3.inputs['Scale'].default_value=140.0; n3.inputs['Detail'].default_value=8.0
cr = nt.nodes.new('ShaderNodeMapRange'); cr.location=(-560,340)
cr.inputs['To Min'].default_value=0.032; cr.inputs['To Max'].default_value=0.072
link(nt,n3,'Fac',cr,'Value'); link(nt,cr,'Result',bsdf,'Base Color')

# ---- line material: bevelled bright-ish metal-paint
line_mat, nt, out = mat('line')
b = nt.nodes.new('ShaderNodeBsdfPrincipled')
b.inputs['Base Color'].default_value=(0.42,0.44,0.47,1)
b.inputs['Metallic'].default_value=0.85
b.inputs['Roughness'].default_value=0.28
link(nt,b,'BSDF',out,'Surface')

# ---- note-disk material: black metal + per-object blackbody emission
disk_mat, nt, out = mat('notedisk')
b = nt.nodes.new('ShaderNodeBsdfPrincipled'); b.location=(0,0)
b.inputs['Base Color'].default_value=(0.012,0.012,0.013,1)
b.inputs['Metallic'].default_value=1.0
b.inputs['Roughness'].default_value=DISK_ROUGH
link(nt,b,'BSDF',out,'Surface')
attr = nt.nodes.new('ShaderNodeAttribute'); attr.location=(-1000,-200)
attr.attribute_type='OBJECT'; attr.attribute_name='heat'
bbt = nt.nodes.new('ShaderNodeMapRange'); bbt.location=(-800,-100)
bbt.inputs['To Min'].default_value=950.0; bbt.inputs['To Max'].default_value=6800.0
link(nt,attr,'Fac',bbt,'Value')
bb = nt.nodes.new('ShaderNodeBlackbody'); bb.location=(-620,-100)
link(nt,bbt,'Result',bb,'Temperature'); link(nt,bb,'Color',b,'Emission Color')
pw = nt.nodes.new('ShaderNodeMath'); pw.location=(-800,-360); pw.operation='POWER'
pw.inputs[1].default_value=2.6
link(nt,attr,'Fac',pw,0)
mu = nt.nodes.new('ShaderNodeMath'); mu.location=(-620,-360); mu.operation='MULTIPLY'
mu.inputs[1].default_value=62.0
link(nt,pw,'Value',mu,0); link(nt,mu,'Value',b,'Emission Strength')

# ---- playhead material: flat glowing disk
def emissive(name, col, strength):
    m, nt, out = mat(name)
    e = nt.nodes.new('ShaderNodeEmission')
    e.inputs['Color'].default_value=col; e.inputs['Strength'].default_value=strength
    link(nt,e,'Emission',out,'Surface')
    return m
head_mat = emissive('playhead',(0.60,0.82,1.0,1.0), 17.0)
perc_mat = emissive('percdisk',(1.0,0.62,0.28,1.0), 40.0)

# ---- comet tail: transparent-mixed emission tapering to exactly nothing
tail_mat, nt, out = mat('comet')
em = nt.nodes.new('ShaderNodeEmission'); em.location=(-200,120)
em.inputs['Color'].default_value=(0.55,0.80,1.0,1.0); em.inputs['Strength'].default_value=19.0
tr = nt.nodes.new('ShaderNodeBsdfTransparent'); tr.location=(-200,-60)
mx = nt.nodes.new('ShaderNodeMixShader'); mx.location=(60,0)
nt.links.new(tr.outputs['BSDF'], mx.inputs[1])
nt.links.new(em.outputs['Emission'], mx.inputs[2])
link(nt,mx,'Shader',out,'Surface')
tc = nt.nodes.new('ShaderNodeTexCoord'); tc.location=(-1000,-260)
sx = nt.nodes.new('ShaderNodeSeparateXYZ'); sx.location=(-820,-260)
link(nt,tc,'Object',sx,'Vector')
TAIL_LEN = 1.6
mr = nt.nodes.new('ShaderNodeMapRange'); mr.location=(-640,-260)
mr.inputs['From Min'].default_value=-TAIL_LEN; mr.inputs['From Max'].default_value=0.0
mr.inputs['To Min'].default_value=0.0; mr.inputs['To Max'].default_value=1.0
mr.clamp=True
link(nt,sx,'Y',mr,'Value')
tp = nt.nodes.new('ShaderNodeMath'); tp.location=(-460,-260); tp.operation='POWER'
tp.inputs[1].default_value=3.2
link(nt,mr,'Result',tp,0)
nt.links.new(tp.outputs['Value'], mx.inputs['Fac'])
tail_mat.blend_method = 'BLEND' if hasattr(tail_mat,'blend_method') else None
if hasattr(tail_mat,'surface_render_method'): tail_mat.surface_render_method='BLENDED'

# ---------------------------------------------------------------- geometry
Y0, Y1 = -12.0, 42.0
THICK  = 0.20

def newobj(name, me):
    o = bpy.data.objects.new(name, me); sc.collection.objects.link(o); return o

# road slab
bpy.ops.mesh.primitive_cube_add(size=2, location=(0,(Y0+Y1)/2, -THICK/2))
road = bpy.context.object; road.name='road'
road.scale = (3.6, (Y1-Y0)/2, THICK/2)
bpy.ops.object.transform_apply(scale=True)
road.data.materials.append(road_mat)

# perc hole cutters
cutters=[]
for i,tp_ in enumerate(PERC):
    bpy.ops.mesh.primitive_cylinder_add(radius=0.44, depth=2.0, vertices=48,
                                        location=(PERC_X, V*tp_, 0))
    c = bpy.context.object; c.name=f'cut{i}'; c.hide_render=True; cutters.append(c)
for c in cutters:
    m = road.modifiers.new(f'bool_{c.name}','BOOLEAN')
    m.operation='DIFFERENCE'; m.object=c; m.solver='EXACT'
bv = road.modifiers.new('bev','BEVEL')
bv.width=0.012; bv.segments=3; bv.limit_method='ANGLE'; bv.angle_limit=math.radians(35)
bv.harden_normals=True
for p in road.data.polygons: p.use_smooth=True

# track lines (bevelled boxes)
for i,lx in enumerate([-2.5,-1.5,-0.5,0.5,1.5,2.5]):
    bpy.ops.mesh.primitive_cube_add(size=2, location=(lx,(Y0+Y1)/2, 0.006))
    o = bpy.context.object; o.name=f'line{i}'
    o.scale=(0.036,(Y1-Y0)/2,0.026); bpy.ops.object.transform_apply(scale=True)
    o.data.materials.append(line_mat)
    m=o.modifiers.new('bev','BEVEL'); m.width=0.008; m.segments=3
    m.limit_method='ANGLE'; m.angle_limit=math.radians(30); m.harden_normals=True
    for p in o.data.polygons: p.use_smooth=True

# note disks -- bevelled, thin, black
DISK_R, DISK_D = 0.30, 0.07
disks=[]
for ci,(tc_, lanes) in enumerate(CHORDS):
    for ln in lanes:
        bpy.ops.mesh.primitive_cylinder_add(radius=DISK_R, depth=DISK_D, vertices=64,
                                            location=(LANE_X[ln], V*tc_, DISK_D/2+0.004))
        d = bpy.context.object; d.name=f'note_{ci}_{ln}'
        d.data.materials.append(disk_mat)
        m=d.modifiers.new('bev','BEVEL'); m.width=0.018; m.segments=4
        m.limit_method='ANGLE'; m.angle_limit=math.radians(30); m.harden_normals=True
        for p in d.data.polygons: p.use_smooth=True
        d['heat']=0.0
        disks.append((d, tc_))

# rig empty: camera + key light + playheads all travel at V
rig = bpy.data.objects.new('rig', None); sc.collection.objects.link(rig)

cam_d = bpy.data.cameras.new('cam'); cam_d.lens=40.0
cam = newobj('camera', cam_d); cam.parent=rig
cam.location=(0.0,-7.4,3.85); cam.rotation_euler=(math.radians(70.0),0,0)
sc.camera = cam

key_d = bpy.data.lights.new('key','AREA'); key_d.energy=520.0
key_d.shape='RECTANGLE'; key_d.size=7.0; key_d.size_y=3.0
key = newobj('key', key_d); key.parent=rig
key.location=(-1.0,3.0,6.0); key.rotation_euler=(math.radians(18),math.radians(-10),0)

rim_d = bpy.data.lights.new('rim','AREA'); rim_d.energy=260.0
rim_d.shape='RECTANGLE'; rim_d.size=6.0; rim_d.size_y=1.4
rim = newobj('rim', rim_d); rim.parent=rig
rim.location=(2.6,-1.5,2.2); rim.rotation_euler=(math.radians(72),0,math.radians(-70))

HEAD_R, HEAD_Z = 0.19, 0.36
# playheads + comet tails
heads=[]
for ln,lx in enumerate(LANE_X):
    bpy.ops.mesh.primitive_cylinder_add(radius=HEAD_R, depth=0.014, vertices=64,
                                        location=(lx,0.0,HEAD_Z))
    h = bpy.context.object; h.name=f'head{ln}'
    h.data.materials.append(head_mat); h.parent=rig
    h.visible_shadow=False
    heads.append(h)
    # tail: quad strip, full disk width at head, monotonic to a point
    me = bpy.data.meshes.new(f'tail{ln}')
    bm = bmesh.new()
    N=44; W=HEAD_R
    prevL=prevR=None
    for i in range(N+1):
        u=i/N
        w = W*(1.0-u)**0.85
        y = -TAIL_LEN*u
        vl = bm.verts.new((-w,y,0.0)); vr = bm.verts.new((w,y,0.0))
        if prevL is not None: bm.faces.new((prevL,prevR,vr,vl))
        prevL,prevR = vl,vr
    bm.to_mesh(me); bm.free()
    t = newobj(f'tail{ln}', me); t.data.materials.append(tail_mat)
    t.parent=rig; t.location=(lx,0.0,HEAD_Z-0.012); t.visible_shadow=False

# percussion jump disks
percs=[]
for i,tp_ in enumerate(PERC):
    bpy.ops.mesh.primitive_cylinder_add(radius=0.30, depth=0.02, vertices=48,
                                        location=(PERC_X, V*tp_, -0.30))
    p = bpy.context.object; p.name=f'perc{i}'
    p.data.materials.append(perc_mat); p.visible_shadow=False
    percs.append((p, tp_))

# ---------------------------------------------------------------- world
w = bpy.data.worlds.new('w'); sc.world = w; w.use_nodes=True
wnt = w.node_tree
for n in list(wnt.nodes): wnt.nodes.remove(n)
wout = wnt.nodes.new('ShaderNodeOutputWorld')
bg = wnt.nodes.new('ShaderNodeBackground'); bg.inputs['Strength'].default_value=1.0
wnt.links.new(bg.outputs['Background'], wout.inputs['Surface'])
wtc = wnt.nodes.new('ShaderNodeTexCoord')
wsx = wnt.nodes.new('ShaderNodeSeparateXYZ')
wnt.links.new(wtc.outputs['Generated'], wsx.inputs['Vector'])
ramp = wnt.nodes.new('ShaderNodeValToRGB')
ramp.color_ramp.interpolation='EASE'
e0 = ramp.color_ramp.elements[0]; e0.position=0.30; e0.color=(0.006,0.007,0.010,1)
e1 = ramp.color_ramp.elements[1]; e1.position=0.62; e1.color=(0.30,0.36,0.46,1)
e2 = ramp.color_ramp.elements.new(0.50); e2.color=(0.055,0.065,0.085,1)
wnt.links.new(wsx.outputs['Z'], ramp.inputs['Fac'])
wnt.links.new(ramp.outputs['Color'], bg.inputs['Color'])

# ---------------------------------------------------------------- bake animation
for f in range(1, NFR+1):
    t = t_of(f)
    rig.location = (0.0, V*t, 0.0)
    rig.keyframe_insert('location', frame=f)
    for d,t0 in disks:
        d['heat'] = heat(t,t0)
        d.keyframe_insert('["heat"]', frame=f)
    for p,tp_ in percs:
        d_ = t - tp_
        if d_ < 0.0 or d_ > 0.62:
            z = -0.30
        else:
            u = d_/0.62
            z = -0.30 + 1.30*(4*u*(1-u))**0.7      # up and back down
        p.location = (PERC_X, V*tp_, z)
        p.keyframe_insert('location', frame=f)

# ---------------------------------------------------------------- engine
if ENGINE.startswith('CYC'):
    sc.render.engine='CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type='METAL'; prefs.get_devices()
    for d in prefs.devices:
        d.use = (d.type=='METAL')
    prefs.get_devices()
    for d in prefs.devices:
        print(f"[cycles-device] {d.name!r} type={d.type} use={d.use}")
    sc.cycles.device='GPU'
    sc.cycles.samples=SAMPLES
    sc.cycles.use_denoising=True
    sc.cycles.use_adaptive_sampling=True
    sc.cycles.sample_clamp_indirect=10.0
    sc.cycles.max_bounces=8
    sc.cycles.transparent_max_bounces=12
else:
    sc.render.engine='BLENDER_EEVEE'
    try:
        sc.eevee.taa_render_samples=64
        sc.eevee.use_bloom=True
    except Exception as e:
        print('[eevee] partial config:', e)

# ---------------------------------------------------------------- key frames report
def f_of(t): return int(round(t*FPS))+1
report = {
  'rest'      : f_of(0.50),
  'strike'    : f_of(CHORDS[0][0])+2,
  'midcool'   : f_of(CHORDS[0][0]+0.34),
  'comet'     : f_of(CHORDS[1][0]+0.55),
  'perchole'  : f_of(PERC[3]+0.31),
  'bigchord'  : f_of(CHORDS[4][0])+2,
}
print('[frames]', json.dumps(report))
print('[heat-check]', json.dumps({k: round(max(heat(t_of(v),c[0]) for c in CHORDS),4)
                                  for k,v in report.items()}))

# ---------------------------------------------------------------- render
times=[]
def _pre(*a): times.append(time.perf_counter())
def _post(*a): times.append(time.perf_counter())
bpy.app.handlers.render_pre.append(_pre)
bpy.app.handlers.render_post.append(_post)

if ANIM:
    sc.render.filepath = os.path.join(OUT, 'frames', 'f')
    sc.render.image_settings.color_mode='RGB'
    t0=time.perf_counter()
    bpy.ops.render.render(animation=True)
    print(f'[anim] {NFR} frames in {time.perf_counter()-t0:.1f}s')
else:
    for f in FRAMES:
        sc.frame_set(f)
        sc.render.filepath = os.path.join(OUT, f'{TAG}_f{f:04d}')
        t0=time.perf_counter()
        bpy.ops.render.render(write_still=True)
        print(f'[time] frame {f}: {time.perf_counter()-t0:.2f}s -> {sc.render.filepath}.png')
print('[done]', ENGINE, 'rough=',DISK_ROUGH, 'decay=',DECAY_T)
