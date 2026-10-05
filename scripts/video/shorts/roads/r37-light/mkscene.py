# ROUND 37 — rebuild ONE resolved instant of the r36 stage in Blender.
#
# ⭐⭐ THE RULE THAT MAKES THIS A RENDERER COMPARISON AT ALL: this file contains
# NO envelope logic, NO pitch->height map, NO camera interpolation and NO
# payload parsing. Every one of those already exists in stage.html, and a Python
# re-implementation of them would mean any difference between the three pictures
# was a difference between two IMPLEMENTATIONS. `scene/*.json` is the RESOLVED
# state dumped straight out of the running three.js scene by `window.__dumpScene()`
# — world positions, resolved heights and radii, LINEAR colours, light
# intensities, ring alphas, and the resolved camera. Blender receives
# coordinates.
#
# ⚠ AND IT IS ONE SCENE, TWO ENGINES. EEVEE and Cycles are handed byte-identical
# geometry, materials, lights and volume; only `render.engine` and each engine's
# own sampling settings differ.
import bpy, json, sys, math, os, time
from mathutils import Vector, Quaternion

argv = sys.argv[sys.argv.index('--') + 1:]
SCENE_JSON = argv[0]
ENGINE     = argv[1]                    # EEVEE | CYCLES
OUT        = argv[2]
SIGMA_MODE = argv[3] if len(argv) > 3 else 'matched'   # matched | haze
SAMPLES    = int(argv[4]) if len(argv) > 4 else 0      # 0 = engine default below
VOLSAMPLES = int(argv[5]) if len(argv) > 5 else 64     # EEVEE volumetric samples
S = json.load(open(SCENE_JSON))

# ---------------------------------------------------------------- the mapping
# three.js is Y-up; Blender is Z-up. (x, y, z)_three -> (x, -z, y)_blender.
# ⚠ THAT SIGN IS LOAD-BEARING: dropping it gives a MIRRORED rig that looks
# perfectly plausible. It is checked below against __rodScreen()'s own pixel
# coordinates, with a control that flips it.
def B(x, y, z):  return Vector((x, -z, y))
def Bv(d):       return B(d['x'], d['y'], d['z'])
def col(c, k=1.0): return (c['r'] * k, c['g'] * k, c['b'] * k, 1.0)

# ── HAZE. three.js FogExp2 attenuates as 1 - exp(-(k*d)^2); a Blender volume
# attenuates as exp(-sigma*d). They are not the same law, so they are matched at
# ONE distance and the derivation is stated rather than tuned:
#   k = 0.034, d = 13.5 (the mid pose's camera radius)
#   fogged   = 1 - exp(-(0.034*13.5)^2) = 0.1900   -> transmittance 0.8100
#   sigma    = -ln(0.8100) / 13.5       = 0.01561  per unit
K_FOG = S['look']['fogDensity']; D_REF = 13.5
SIGMA_MATCHED = -math.log(math.exp(-(K_FOG * D_REF) ** 2)) / D_REF
# ⚠ AND A SECOND, HONEST VALUE. sigma_matched is what the REJECTED picture's fog
# implies, and it is very thin — theatrical haze is far denser. So both engines
# also render at a real stage-haze density, and both numbers are reported. This
# is an axis applied IDENTICALLY to both engines, not a per-renderer tune.
SIGMA_HAZE = float(os.environ.get('SIGMA_HAZE', '0.16'))
SIGMA = SIGMA_MATCHED if SIGMA_MODE == 'matched' else SIGMA_HAZE

# ── LIGHT UNITS. three.js PointLight(intensity I, distance 9.5, decay 1.6) is
# not watts. Irradiance three.js ~ I / d^1.6 ; Blender point ~ P / (4*pi*d^2).
# Matched at a reference distance of 2.0 units (a typical floor-pool radius):
#   P = I * 4*pi*4 / 2^1.6 = I * 16.60
D_LIGHT_REF = 2.0
W_PER_INTENSITY = 4 * math.pi * D_LIGHT_REF ** 2 / (D_LIGHT_REF ** 1.6)
# ── EMISSION. ⭐⭐ A ROD IS A REAL LIGHT SOURCE HERE, WITH NO FREE PARAMETER.
# In three.js a rod is a LIT cylinder plus a separate PointLight — the surface's
# brightness and the light it casts are two unrelated numbers, and the surface
# one bypasses tone mapping entirely. That split is exactly the artificiality
# being complained about, so it is not carried over. Instead the rod IS the
# emitter: its radiance is derived from the wattage the PointLight maps to,
# spread over the rod's OWN surface area.
#     P = I * W_PER_INTENSITY          (watts, from the mapping above)
#     A = 2*pi*r*h                     (the rod's lateral area)
#     L = P / (pi * A)                 (Lambertian exitance M = pi*L)
# For this instant that lands at L = 13-17 for every rod, which is worth
# noticing: it is where a first GUESS of 12 also landed, and nowhere near the
# 2.0 that matching the REJECTED image's rod pixels asks for. Matching the
# rejected picture reproduces the rejected picture.
def rod_radiance(I, r, h):
    A = 2 * math.pi * max(1e-6, r) * max(1e-6, h)
    return (I * W_PER_INTENSITY) / (math.pi * A)
# Floor decals (deck edge, memory rings, hole embers, caps) are not physical
# lights in either build — they are three.js additive overlays. One scalar,
# identical in both engines.
DECAL = float(os.environ.get('DECAL', '12.0'))
LAMP  = os.environ.get('LAMP', 'point')      # 'mesh' | 'point'
EMIT = DECAL

# ---------------------------------------------------------------- fresh scene
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
W, H = S['camera']['W'], S['camera']['H']
sc.render.resolution_x, sc.render.resolution_y = W, H
sc.render.resolution_percentage = 100
sc.render.film_transparent = False
sc.view_settings.view_transform = 'AgX'      # Blender ships no ACES; AgX is the
sc.view_settings.look = 'None'               # modern default and handles the
sc.view_settings.exposure = 0.0              # blown emissive cores gracefully.
sc.render.image_settings.file_format = 'PNG'
sc.render.image_settings.color_depth = '8'

world = bpy.data.worlds.new('W'); sc.world = world
world.use_nodes = True
# ⚠ THE WORLD IS TWO DIFFERENT THINGS IN BLENDER AND ONE IN THREE.JS. three.js
# has a BLACK background AND a weak AmbientLight; a Blender world with a
# non-zero strength is both at once, and the first probe frame came back with a
# grey sky and a grey floor because of it. So the world is split on Is Camera
# Ray: black to the camera, `look.ambient` to everything else.
wnt = world.node_tree; wnt.nodes.clear()
w_lit = wnt.nodes.new('ShaderNodeBackground')
w_cam = wnt.nodes.new('ShaderNodeBackground')
w_mix = wnt.nodes.new('ShaderNodeMixShader')
w_lp  = wnt.nodes.new('ShaderNodeLightPath')
w_out = wnt.nodes.new('ShaderNodeOutputWorld')
w_cam.inputs[0].default_value = (0.0, 0.0, 0.0, 1.0); w_cam.inputs[1].default_value = 0.0
w_lit.inputs[0].default_value = (1.0, 1.0, 1.0, 1.0)
wnt.links.new(w_lp.outputs['Is Camera Ray'], w_mix.inputs['Fac'])
wnt.links.new(w_lit.outputs[0], w_mix.inputs[1])
wnt.links.new(w_cam.outputs[0], w_mix.inputs[2])
wnt.links.new(w_mix.outputs[0], w_out.inputs['Surface'])
bg = w_lit

def emissive(name, rgba, strength):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    e = nt.nodes.new('ShaderNodeEmission')
    o = nt.nodes.new('ShaderNodeOutputMaterial')
    e.inputs[0].default_value = rgba
    e.inputs[1].default_value = strength
    nt.links.new(e.outputs[0], o.inputs[0])
    return m

def diffuse(name, rgba, rough):
    m = bpy.data.materials.new(name); m.use_nodes = True
    p = m.node_tree.nodes['Principled BSDF']
    p.inputs['Base Color'].default_value = rgba
    p.inputs['Roughness'].default_value = rough
    p.inputs['Metallic'].default_value = 0.05
    return m

def hex2lin(h):
    # the payload's hex are sRGB; three.js converts to linear on the way in
    def c(u):
        u = u / 255.0
        return u / 12.92 if u <= 0.04045 else ((u + 0.055) / 1.055) ** 2.4
    return (c((h >> 16) & 255), c((h >> 8) & 255), c(h & 255), 1.0)

L = S['look']

# ---- floor -----------------------------------------------------------------
bpy.ops.mesh.primitive_circle_add(vertices=96, radius=L['floorR'], fill_type='NGON',
                                  location=(0, 0, 0))
floor = bpy.context.object; floor.name = 'floor'
floor.data.materials.append(diffuse('floor', hex2lin(L['floorColor']), L['floorRough']))

# ---- the deck edge ring (faint, additive in three.js -> emissive here) ------
bpy.ops.mesh.primitive_torus_add(major_radius=L['deckR'], minor_radius=0.012,
                                 major_segments=128, minor_segments=6, location=(0, 0, 0.01))
deck = bpy.context.object; deck.name = 'deck'
deck.data.materials.append(emissive('deck', hex2lin(L['deckColor']), EMIT * L['deckAlpha']))

# ---- risers ----------------------------------------------------------------
riser_mat = diffuse('riser', hex2lin(L['riserColor']), 0.92)
# NORISERS=1 removes every riser — the A/B that turns "I could not see a shadow"
# into a measurement of how much light the risers actually block, in the haze
# and on the floor separately.
for r in ([] if os.environ.get('NORISERS') == '1' else S['risers']):
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=r['r'], depth=r['top'],
        location=B(r['x'], r['top'] / 2.0, r['z']))
    o = bpy.context.object; o.name = 'riser-' + r['name']
    o.data.materials.append(riser_mat)

# ---- holes + embers --------------------------------------------------------
hole_mat = diffuse('hole', hex2lin(L['holeColor']), 1.0)
for h in S['holes']:
    bpy.ops.mesh.primitive_circle_add(vertices=32, radius=h['r'], fill_type='NGON',
        location=B(h['x'], h['y'] + 0.004, h['z']))
    o = bpy.context.object; o.data.materials.append(hole_mat)
    if h['emberVisible'] and h['emberAlpha'] > 0.002:
        bpy.ops.mesh.primitive_circle_add(vertices=32, radius=h['emberR'], fill_type='NGON',
            location=B(h['x'], h['y'] + 0.006, h['z']))
        e = bpy.context.object
        e.data.materials.append(emissive('ember', col(h['emberColor']), EMIT * h['emberAlpha']))
for k in S['kitHoles']:
    bpy.ops.mesh.primitive_circle_add(vertices=32, radius=k['r'], fill_type='NGON',
        location=B(k['x'], 0.004, k['z']))
    bpy.context.object.data.materials.append(hole_mat)

# ---- floor memory rings ----------------------------------------------------
for i, rg in enumerate(S['rings']):
    bpy.ops.mesh.primitive_torus_add(major_radius=rg['r'], minor_radius=rg['r'] * 0.055,
        major_segments=64, minor_segments=6, location=B(rg['x'], 0.008, rg['z']))
    o = bpy.context.object; o.name = f'ring{i}'
    o.data.materials.append(emissive(f'ringm{i}', col(rg['color']), EMIT * rg['alpha']))

# ---- rods: an emissive cylinder AND the point light three.js already had ----
# ⚠ THE SHEATH IS DELIBERATELY NOT BUILT. Its entire job in three.js is to FAKE
# a beam in haze with an additive tube; here the haze is real and scatters the
# lamp for itself. Keeping it would be putting a painted beam inside a real one.
rods_for_check = []
for r in S['rods']:
    base = B(r['x'], r['y'], r['z'])
    bpy.ops.mesh.primitive_cylinder_add(vertices=28, radius=r['radius'], depth=r['height'],
        location=(base.x, base.y, base.z + r['height'] / 2.0))
    o = bpy.context.object; o.name = f"rod-{r['name']}-{r['k']}"
    Lrad = rod_radiance(r['lightIntensity'], r['radius'], r['height'])
    o.data.materials.append(emissive(f"rodm{r['i']}{r['k']}", col(r['color']), Lrad))
    print('  ROD %-8s k=%d  r=%.3f h=%.2f  I=%.2f -> %.1f W -> radiance %.1f'
          % (r['name'], r['k'], r['radius'], r['height'], r['lightIntensity'],
             r['lightIntensity'] * W_PER_INTENSITY, Lrad))
    # ⭐⭐ TWO LAMP CONFIGURATIONS, AND THE DIFFERENCE BETWEEN THEM IS A MEASURED
    # RENDERER FACT, NOT A TASTE. In LAMP=mesh the emissive cylinder IS the
    # light — the physically right build, and the only one that gives a
    # ROD-SHAPED column of scattered light. In LAMP=point the rod's emission is
    # camera-visible only and the same watts come from a point lamp inside it.
    # Config `point` exists because EEVEE Next does not light volumes from mesh
    # emission at all (measured, §EEVEE below), so `mesh` cannot be an
    # apples-to-apples speed comparison and `point` can.
    if LAMP == 'point':
        # ⛔⛔ `visible_shadow` IS THE ONE THAT MATTERS AND IT IS NOT OPTIONAL.
        # The lamp sits INSIDE the rod cylinder. The four ray-visibility flags
        # below are CYCLES-only; EEVEE ignores them, so without also clearing
        # visible_shadow the rod's own opaque wall blocks its own lamp and EEVEE
        # renders no pools and no scattering at all. That looked EXACTLY like
        # "EEVEE cannot light volumes" — a build bug wearing a renderer
        # finding's clothes, caught only by noticing the floor had no pools.
        for a in ('visible_diffuse', 'visible_glossy', 'visible_transmission',
                  'visible_volume_scatter', 'visible_shadow'):
            if hasattr(o, a): setattr(o, a, False)
        lt = bpy.data.lights.new(f"L{r['i']}{r['k']}", type='POINT')
        lt.color = (r['lightColor']['r'], r['lightColor']['g'], r['lightColor']['b'])
        lt.energy = r['lightIntensity'] * W_PER_INTENSITY
        lt.shadow_soft_size = max(0.02, r['radius'])
        lo = bpy.data.objects.new(lt.name, lt); sc.collection.objects.link(lo)
        lo.location = B(r['x'], r['y'] + r['height'] * 0.5, r['z'])
    if r['capVisible'] and r['capAlpha'] > 0.01:
        bpy.ops.mesh.primitive_uv_sphere_add(radius=max(0.03, r['capSize'] * 0.30),
            location=B(r['x'], r['y'] + r['capY'], r['z']))
        c = bpy.context.object; c.name = f"cap{r['i']}{r['k']}"
        c.data.materials.append(emissive(f"capm{r['i']}{r['k']}", col(r['color']),
                                         EMIT * 2.0 * r['capAlpha']))
    rods_for_check.append((r, base.z + r['height']))

# ---- the kit, mid-leap -----------------------------------------------------
for i, k in enumerate(S['kit']):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=k['coreR'], location=Bv(k))
    o = bpy.context.object; o.name = f"kit{i}"
    o.scale = (1.0, 1.0, k['coreH'] / max(1e-6, k['coreR']))
    # same rule as a rod: the glowing core IS the lamp, radiance from its area
    A = 4 * math.pi * max(1e-6, k['coreR']) ** 2
    Lk = (k['lightIntensity'] * W_PER_INTENSITY) / (math.pi * A)
    o.data.materials.append(emissive(f"kitm{i}", (1.0, 0.977, 0.944, 1.0), Lk))
    if LAMP == 'point':
        for a in ('visible_diffuse', 'visible_glossy', 'visible_transmission',
                  'visible_volume_scatter', 'visible_shadow'):
            if hasattr(o, a): setattr(o, a, False)
        lt = bpy.data.lights.new(f"KL{i}", type='POINT')
        lt.color = (k['lightColor']['r'], k['lightColor']['g'], k['lightColor']['b'])
        lt.energy = k['lightIntensity'] * W_PER_INTENSITY
        lt.shadow_soft_size = 0.05
        lo = bpy.data.objects.new(lt.name, lt); sc.collection.objects.link(lo)
        lo.location = Bv(k)

# ---- a very low ambient, matching three.js's AmbientLight ------------------
bg.inputs[1].default_value = L['ambient']

# ---- THE HAZE: a BOUNDED volume, not a world volume ------------------------
# ⚠ A world volume is unbounded, which is both the thing three.js does NOT have
# and the single biggest way to make a Cycles volume render explode.
VR = L['floorR']
bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 9.0))
vol = bpy.context.object; vol.name = 'haze'
vol.scale = (VR * 2, VR * 2, 18.0)  # tall enough that the HIGH pose's camera is inside it too
vm = bpy.data.materials.new('haze'); vm.use_nodes = True
nt = vm.node_tree; nt.nodes.clear()
pv = nt.nodes.new('ShaderNodeVolumePrincipled')
om = nt.nodes.new('ShaderNodeOutputMaterial')
pv.inputs['Color'].default_value = (1.0, 1.0, 1.0, 1.0)
pv.inputs['Density'].default_value = SIGMA
pv.inputs['Anisotropy'].default_value = 0.30   # mild forward scatter; real haze
nt.links.new(pv.outputs[0], om.inputs['Volume'])
vol.data.materials.append(vm)
vol.visible_shadow = False

# ---- camera ----------------------------------------------------------------
cd = bpy.data.cameras.new('cam')
cd.sensor_fit = 'VERTICAL'                       # three.js `fov` is VERTICAL
cd.angle_y = math.radians(S['camera']['fovDegVertical'])
cd.clip_start, cd.clip_end = 0.05, 200.0
cam = bpy.data.objects.new('cam', cd); sc.collection.objects.link(cam)
sc.camera = cam
cp = Bv(S['camera']['position'])
tg = B(*S['camera']['target'])
cam.location = cp
cam.rotation_mode = 'QUATERNION'
cam.rotation_quaternion = (cp - tg).to_track_quat('Z', 'Y')

# ---------------------------------------------------------------- ALIGNMENT
# ⚠ "SAME CAMERA" IS A CLAIM UNTIL IT IS A NUMBER. Project every rod cap through
# Blender's camera and compare with __rodScreen()'s own pixel coordinates for
# the same slot. A handedness slip or a horizontal-fit FOV both produce a
# perfectly plausible picture and a large delta here.
from bpy_extras.object_utils import world_to_camera_view
dg = bpy.context.evaluated_depsgraph_get()
bpy.context.view_layer.update()
by_slot = {(rr['i'], rr['k']): rr for rr in S['rodScreen']}
worst, rows = 0.0, []
for r, capz in rods_for_check:
    ref = by_slot.get((r['i'], r['k']))
    if not ref: continue
    p = world_to_camera_view(sc, cam, Vector((B(r['x'], 0, r['z']).x, B(r['x'], 0, r['z']).y, capz)))
    px, py = p.x * W, (1.0 - p.y) * H
    d = math.hypot(px - ref['capX'], py - ref['capY'])
    worst = max(worst, d)
    rows.append(f"  {r['name']}-{r['k']}: blender=({px:7.1f},{py:7.1f}) three=({ref['capX']:7.1f},{ref['capY']:7.1f})  delta={d:6.2f} px")
print('ALIGNMENT: worst cap delta = %.2f px  over %d rods' % (worst, len(rows)))
for r in rows: print(r)

# ---------------------------------------------------------------- engines
if ENGINE == 'CYCLES':
    sc.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices:
        d.use = (d.type == 'METAL')
    print('CYCLES devices:', [(d.name, d.type, d.use) for d in prefs.devices])
    sc.cycles.device = os.environ.get('CYCLES_DEVICE', 'GPU')
    sc.cycles.samples = SAMPLES or 128
    sc.cycles.use_adaptive_sampling = False
    sc.cycles.use_denoising = os.environ.get('DENOISE', '0') == '1'
    sc.cycles.max_bounces = 8
    sc.cycles.volume_bounces = 2
    sc.cycles.volume_step_rate = 1.0
    sc.cycles.volume_max_steps = 1024
    print('CYCLES: device=%s samples=%d denoise=%s' % (sc.cycles.device, sc.cycles.samples, sc.cycles.use_denoising))
else:
    sc.render.engine = 'BLENDER_EEVEE'
    ee = sc.eevee
    ee.taa_render_samples = SAMPLES or 64
    ee.volumetric_samples = VOLSAMPLES
    ee.volumetric_tile_size = os.environ.get('EEVEE_TILE', '4')
    ee.volumetric_start = 0.05
    ee.volumetric_end = 200.0
    ee.use_volumetric_shadows = os.environ.get('VOLSHADOW', '1') == '1'
    if hasattr(ee, 'volumetric_shadow_samples'): ee.volumetric_shadow_samples = int(os.environ.get('VSS', '32'))
    if hasattr(ee, 'volumetric_ray_depth'): ee.volumetric_ray_depth = int(os.environ.get('VRD', '16'))
    if hasattr(ee, 'use_raytracing'): ee.use_raytracing = True
    print('EEVEE: taa=%d volsamples=%d tile=%s volshadow=%s' % (
        ee.taa_render_samples, ee.volumetric_samples, ee.volumetric_tile_size, ee.use_volumetric_shadows))

sc.render.filepath = OUT
t0 = time.perf_counter()
bpy.ops.render.render(write_still=True)
t1 = time.perf_counter()
print('RENDERTIME %.3f s  engine=%s sigma=%s(%.5f) samples=%s vol=%s out=%s'
      % (t1 - t0, ENGINE, SIGMA_MODE, SIGMA, SAMPLES, VOLSAMPLES, OUT))
