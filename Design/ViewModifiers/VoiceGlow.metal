// VoiceGlow.metal
// A narrator's voice as light moving through glass.
//
// This is GlassGlow's fitted look, with the shape known analytically. GlassGlow
// segments the shape from an alpha mask and runs a jump flood for its distance
// field; a voice chip, a pill and a dot are rounded rectangles, so one SDF gives
// the same numbers without the mask, the flood or the mip chain. Everything
// else — the ten lights, the tone curve, the bevel, the dispersion, the rim, the
// inner band and the halo — is copied from GlassGlow's LightModel.swift and
// GlassGlow.metal.
//
// Lengths are in units of the shape's height, origin at its centre, y up, so a
// capsule, a pill and a 12pt dot share one look instead of three.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - The fitted look (GlassGlow LightModel.swift)

constant float GG_HEIGHT = 0.87667f;
constant float GG_CONTRAST = 2.44598f;
constant float3 GG_GAMMA = float3(1.10758f, 1.02676f, 0.906664f);
constant float GG_EDGE_SOFTNESS = 0.00117088f;
constant float GG_DISPERSION = 0.174246f;
constant float GG_BEVEL_WIDTH = 0.143921f;
constant float GG_BEVEL_REFRACTION = 0.0568397f;
constant float GG_BEVEL_EXPONENT = 5.02591f;
constant float GG_RIM_WIDTH = 0.344757f;
constant float GG_RIM_AMBIENT = -0.0444197f;
constant float GG_RIM_LIGHT = -0.0178526f;
constant float GG_RIM_INSET = -0.719181f;
constant float GG_BAND_INSET = 0.798147f;
constant float GG_BAND_WIDTH = 0.00169309f;
constant float GG_BAND_LIGHT = 0.377897f;
constant float GG_BAND_BLUR = 0.12f;
constant float3 GG_RIM_COLOUR = float3(0.000143667f, 0.227882f, 0.000119293f);
constant float GG_MINIMUM_WIDTH = 0.07f;
constant float GG_STRETCH_ASPECT = 0.9f;

// Bloom: the halo around the shape. Gain and Gaussian sigma of each level, the
// sigma a fraction of the shape's height (LightModel.bloom). The source's gains
// assume a large canvas; a chip in a list only needs enough to lift the edge,
// so they are scaled down and the halo is kept close.
constant float GG_BLOOM_GAIN[3] = { 0.2570f, 0.2934f, 0.2427f };
constant float GG_BLOOM_SIGMA[3] = { 0.0499f, 0.1259f, 0.0127f };

// Per light: x, y, z, log radius, intensity (softplus), log aspect, angle; each
// a Fourier series [constant, cos 1..4, sin 1..4] over the six-second loop.
constant float GG_COEFF[10][7][9] = {
        {  // light 0
            { -0.270522f, 0.0734884f, -0.0163163f, 0.0364019f, -0.0493123f, 0.470183f, -0.157843f, -0.0581419f, 0.00408744f },
            { -0.0429584f, 0.236212f, -0.180093f, 0.152558f, -0.0268722f, 0.19855f, -0.0933902f, 0.0463381f, 0.0157928f },
            { 0.332642f, 0.214245f, -0.196284f, -0.0173445f, 0.0221143f, -0.0652527f, 0.313192f, -0.0857799f, 0.00967636f },
            { -0.970396f, 0.344242f, -0.0971993f, -0.0970479f, 0.0487715f, -0.286434f, 0.263122f, -0.0764473f, 0.0173125f },
            { -0.208264f, 0.0680484f, 0.28591f, 0.00994357f, 0.00577623f, -0.430403f, 0.0082648f, -0.0119865f, -0.00462828f },
            { -1.30103f, -0.0486195f, -0.262333f, 0.0509627f, 0.0549935f, -0.0896118f, 0.267812f, 0.0357115f, 0.00757452f },
            { -0.254299f, -0.230625f, -0.257376f, 0.0773329f, 0.0308821f, 0.143169f, -0.201889f, -0.034276f, 0.0514255f }
        },
        {  // light 1
            { -0.0933025f, 0.175955f, -0.0016406f, -0.0945995f, -0.0087086f, -0.203897f, 0.166304f, 0.0458962f, -0.095687f },
            { 0.140012f, 0.344517f, -0.198334f, -0.00231512f, 0.0509999f, -0.128771f, 0.00600263f, -0.0546801f, -0.0310371f },
            { 0.219573f, -0.0266394f, 0.0164338f, -0.0267222f, -0.00104975f, 0.23085f, -0.117879f, -0.0076436f, 0.095074f },
            { -1.83536f, 0.0411759f, -0.268201f, -0.183722f, 0.0372748f, 0.0906299f, -0.19513f, -0.050271f, -0.0104735f },
            { 0.271179f, -0.752229f, -0.152549f, -0.0155225f, 0.00397905f, -0.98563f, -0.163819f, -0.0162305f, -0.0101569f },
            { -1.27377f, -0.243896f, 0.0276051f, 0.0151245f, -0.00126675f, -0.349497f, 0.0805109f, 0.00111294f, -0.00601654f },
            { -0.42876f, -0.208765f, -0.3184f, 0.00796717f, 0.0237647f, 0.0933858f, -0.25028f, -0.037981f, 0.0200022f }
        },
        {  // light 2
            { -0.268837f, 0.192914f, 0.122645f, 0.0526769f, 0.00855427f, 0.0892083f, -0.0995855f, 0.00895228f, 0.0152761f },
            { -0.239084f, 0.58396f, 0.115877f, 0.0521329f, -0.0542162f, -0.121938f, 0.00528051f, 0.0840222f, 0.00415823f },
            { 0.2073f, -0.0298475f, 0.0929642f, -0.013595f, 0.00491334f, 0.338127f, 0.320717f, 0.0356952f, -0.0109657f },
            { -1.18038f, -0.155517f, 0.145019f, 0.0445271f, 0.0712132f, -0.653016f, 0.129117f, 0.0614518f, 0.0126727f },
            { -0.0591065f, 0.269229f, 0.432475f, 0.00700874f, -0.00465795f, 1.18389f, -0.283161f, -0.0254468f, 0.00796293f },
            { -0.914322f, -0.667831f, 0.0208912f, -0.0683753f, 0.0260515f, -0.162494f, -0.047998f, -0.0536839f, 0.0320224f },
            { 0.864043f, -0.0936394f, 0.101063f, 0.0795314f, 0.0204186f, 0.474494f, 0.0300405f, 0.0198973f, -0.0140938f }
        },
        {  // light 3
            { -0.182003f, -0.115641f, -0.00628634f, 0.0428289f, 0.0107668f, -0.0127006f, 0.0216094f, 0.0416483f, -0.0191689f },
            { -0.174616f, 0.149996f, 0.00952245f, -0.00744624f, -0.0117632f, -0.0172719f, -0.0824441f, -0.0288959f, -0.0215121f },
            { -0.115793f, 0.0774891f, -0.178095f, -0.0285971f, -0.0187825f, -0.31894f, -0.01619f, 0.000745585f, 0.00196086f },
            { -1.18597f, -0.0322381f, 0.00407734f, 0.0825314f, 0.0185797f, -0.274533f, 0.0671352f, 0.0292421f, -0.0163497f },
            { 1.29263f, 0.247864f, 0.00158164f, -0.00721324f, 0.00226019f, 1.26864f, -0.0578801f, 0.00487392f, 0.00121643f },
            { -1.02773f, 0.126595f, 0.27327f, 0.0689448f, 0.0339886f, 0.532253f, -0.208231f, -0.0392641f, 0.0176279f },
            { 2.66762f, -0.494051f, 0.123972f, -0.000294111f, 0.0300526f, -0.218403f, -0.0824134f, 0.113548f, 0.0185802f }
        },
        {  // light 4
            { -0.159597f, -0.0480223f, 0.0374866f, 0.0139821f, 0.0294858f, 0.186399f, 0.0611817f, 0.0265318f, 0.058715f },
            { 0.0298503f, 0.456165f, -0.0153618f, -0.00492842f, 0.00812073f, 0.0126587f, 0.0697689f, -0.082051f, -0.0469005f },
            { 0.0673755f, 0.104658f, 0.0497154f, -0.0763348f, -0.027163f, -0.336808f, 0.135599f, 0.0465576f, -0.0170256f },
            { -1.43579f, -0.365356f, 0.148517f, -0.0151532f, -0.00118388f, -0.149188f, 0.0535983f, 0.0594117f, -0.0006684f },
            { 0.949466f, 0.24304f, 0.0252454f, 0.0025415f, 0.0013592f, 0.256666f, -0.00842618f, 0.0261708f, -0.00108436f },
            { -1.6317f, 0.128985f, -0.00562364f, 0.000463417f, 3.23884e-08f, 0.00877798f, -0.000839835f, 1.41331e-06f, -1.38006e-11f },
            { 2.73622f, -0.140272f, 0.0616267f, 0.0243908f, 0.0134062f, 0.247782f, 0.0513152f, 0.0851839f, -0.0196558f }
        },
        {  // light 5
            { -0.133415f, -0.0315583f, -0.175609f, 0.0175395f, 0.0540597f, -0.00803772f, 0.0779087f, -0.157484f, 0.0165405f },
            { -0.16242f, -0.0291467f, 0.274329f, -0.115792f, -0.0100589f, 0.00828795f, 0.00300257f, 0.154213f, -0.0587935f },
            { -0.0608652f, -0.00344814f, 0.0676599f, 0.247142f, -0.0289009f, 0.0949516f, -0.328861f, 0.167505f, 0.015257f },
            { -0.895379f, 0.582413f, -0.163664f, -0.0867776f, -0.013705f, -0.422194f, 0.331183f, -0.0475747f, -0.00440081f },
            { -0.312806f, 0.214078f, 0.103675f, 0.00965844f, -0.00202972f, -0.799347f, -0.00991252f, 0.00292778f, 0.00253382f },
            { -1.28682f, -0.284565f, 0.057066f, 0.0780353f, 0.0264168f, 0.11321f, -0.0865934f, -0.107373f, 0.0324015f },
            { 2.8205f, -0.147632f, -0.00959279f, 0.0196052f, 0.000925275f, -0.195351f, -0.0411802f, -0.00929139f, 0.0303516f }
        },
        {  // light 6
            { 0.149282f, -0.0451196f, -0.0404061f, 0.0785848f, -0.0218502f, -0.0593842f, 0.0580855f, -0.000748707f, -0.0155258f },
            { 0.0196179f, -0.3801f, 0.164163f, 0.0449447f, -0.00246352f, 0.0877352f, -0.140422f, -0.0332868f, 0.0567807f },
            { -0.0787624f, 0.140004f, 0.129333f, -0.102448f, 0.0309953f, -0.0491779f, -0.106531f, 0.0355307f, -0.0183937f },
            { -1.63576f, -0.124643f, -0.0789132f, -0.124677f, 0.00389099f, -0.112781f, -0.0930508f, 0.0402715f, 0.00468907f },
            { 0.634828f, -0.780129f, 0.00600109f, -0.000110519f, 0.00637377f, -0.533781f, -0.0541781f, 0.00177063f, 0.000377121f },
            { -1.17992f, 0.35485f, 0.0620571f, 0.0181902f, 0.00481937f, 0.294933f, 0.0173026f, 0.0106536f, 0.00948745f },
            { 3.58003f, 0.478731f, -0.194774f, -0.020628f, 0.0254718f, 0.792836f, 0.358709f, 0.118005f, -0.00254837f }
        },
        {  // light 7
            { 0.164852f, -0.239584f, -0.115133f, -0.0706956f, 0.0126062f, 0.174896f, -0.0118814f, 0.085269f, 0.022942f },
            { 0.177966f, -0.2319f, -0.0638296f, 0.00442093f, 0.0300794f, -0.0639806f, 0.153651f, 0.0342093f, 0.00535193f },
            { 0.0683294f, -0.167158f, -0.00412879f, 0.0208185f, 0.00989585f, 0.204056f, 0.0594996f, 0.00440323f, -0.0247648f },
            { -1.39746f, 0.411975f, 0.00273433f, 0.00760946f, -0.0443983f, 0.00936572f, -0.227137f, -0.144256f, -0.0335429f },
            { -0.165313f, -1.10688f, -0.183124f, 0.0144261f, 0.00322319f, -0.00853281f, 0.228776f, -0.0671722f, -0.0101707f },
            { -0.826797f, 0.211716f, 0.0588945f, -0.0110715f, -0.00117074f, 0.11408f, -0.0513495f, 0.00802701f, -0.0179305f },
            { 4.15387f, -0.439086f, 0.0388287f, -0.0375431f, -0.0131379f, -0.699553f, 0.604455f, -0.142354f, 0.0210343f }
        },
        {  // light 8
            { -0.0394116f, 0.0580647f, 0.00855449f, -0.00385035f, 0.0160571f, -0.00691884f, 0.0786019f, 0.011063f, 0.0148032f },
            { 0.200324f, -0.0337324f, -0.0985055f, -0.0322615f, -0.0130752f, 0.131552f, 0.0605442f, 0.0116634f, 0.0109688f },
            { -0.328201f, -0.123983f, -0.231239f, 0.00982393f, 0.0450688f, -0.0118899f, -0.0688328f, -0.114372f, -0.0157878f },
            { -1.34267f, 0.361452f, 0.38506f, -0.0331155f, -0.0533612f, 0.0628361f, 0.168089f, 0.0995761f, 0.00587417f },
            { 1.2169f, -0.148125f, -0.0406666f, 0.00920045f, 0.00249416f, -0.957847f, -0.00868388f, -0.0117866f, 0.00400732f },
            { -1.1906f, 0.193341f, 0.093661f, -0.00961354f, -0.0192602f, -0.53649f, -0.3465f, -0.0857918f, -0.0199012f },
            { 5.74793f, -0.732855f, -0.177963f, 0.0495554f, 0.0081352f, -0.276365f, -0.152047f, 0.0274208f, 0.0327604f }
        },
        {  // light 9
            { 0.00322476f, -0.0728374f, 0.00768746f, 0.0184534f, 0.0100572f, 0.110837f, 0.219346f, 0.0310853f, -0.0113901f },
            { 0.209407f, -0.134257f, -0.186818f, 0.0436416f, 0.01965f, -0.0485956f, -0.00946123f, 0.062904f, -0.01811f },
            { 0.169792f, 0.474766f, -0.233247f, -0.0813592f, 0.0087067f, -0.0725531f, -0.237395f, 0.0345828f, 0.0215335f },
            { -1.36249f, -0.0187035f, 0.140288f, -0.151012f, 0.0106249f, -0.43475f, -0.00152135f, -0.0356449f, 0.0102116f },
            { -0.34103f, 0.504494f, -0.0558191f, 0.00482903f, 0.00535894f, -0.341361f, 0.0366708f, 0.0122539f, 0.00399501f },
            { -0.847425f, -0.000705862f, -0.139368f, -0.122825f, -0.00707751f, 0.150392f, 0.0839984f, 0.0130372f, 0.00175694f },
            { 5.74824f, 0.405394f, -0.0742329f, 0.0211097f, -0.00466217f, 0.0196054f, 0.00703996f, 0.0648116f, 0.0174966f }
        }
};

// Brightest channel of each fitted light's colour. A palette entry replaces the
// hue but keeps the brightness (LightModel.colours(for:)).
constant float GG_FITTED_PEAK[10] = {
    1.71479f, 3.61297f, 2.66855f, 3.36857f, 3.25416f,
    1.50267f, 3.5775f, 1.89169f, 3.98313f, 1.63041f
};

static float3 voiceHSV(float h, float s, float v) {
    float3 k = float3(1.0f, 2.0f / 3.0f, 1.0f / 3.0f);
    float3 p = abs(fract(float3(h) + k) * 6.0f - 3.0f);
    return v * mix(float3(1.0f), clamp(p - 1.0f, 0.0f, 1.0f), s);
}

/// GlassGlow's ten lights at loop time `t`, in radians of the six-second loop.
struct GGLight {
    float2 pos;
    float z;
    float radius;
    float intensity;
    float aspect;
    float2 cs;
    float3 colour;
};

static void ggLights(float t, float3 hues, thread GGLight lights[10]) {
    float basis[9];
    basis[0] = 1.0f;
    for (int h = 1; h <= 4; h++) basis[h] = cos(t * float(h));
    for (int h = 1; h <= 4; h++) basis[4 + h] = sin(t * float(h));
    for (int k = 0; k < 10; k++) {
        float q[7];
        for (int j = 0; j < 7; j++) {
            float v = 0.0f;
            for (int i = 0; i < 9; i++) v += GG_COEFF[k][j][i] * basis[i];
            q[j] = v;
        }
        float radius = exp(q[3]);
        GGLight light;
        light.pos = float2(q[0], q[1]);
        light.z = q[2];
        light.radius = radius;
        light.intensity = log(1.0f + exp(q[4]));
        light.aspect = max(exp(min(q[5], 0.0f)), GG_MINIMUM_WIDTH / radius);
        light.cs = float2(cos(q[6]), sin(q[6]));
        float hue = k % 3 == 0 ? hues.x : (k % 3 == 1 ? hues.y : hues.z);
        float saturation = k % 3 == 0 ? 0.65f : (k % 3 == 1 ? 0.55f : 0.70f);
        light.colour = voiceHSV(hue, saturation, 1.0f) * GG_FITTED_PEAK[k];
        lights[k] = light;
    }
}

/// The light field at `p` (GlassGlow's gg_light). `blur2` > 0 returns it
/// convolved with a Gaussian — each light widened, its energy kept — for the
/// rim and band samples, which would otherwise flicker.
static float3 ggLightField(float2 p, float depth, float stretch, float blur2, thread const GGLight *lights) {
    p.x /= stretch;
    float z = GG_HEIGHT * sqrt(max(depth, 0.0f) + 1e-6f);
    float3 e = 0.0f;
    for (int k = 0; k < 10; k++) {
        GGLight b = lights[k];
        float ru2 = b.radius * b.radius;
        float rv2 = ru2 * b.aspect * b.aspect;
        float wu2 = ru2 + blur2;
        float wv2 = rv2 + blur2;
        float2 d = p - b.pos;
        float u = d.x * b.cs.x + d.y * b.cs.y;
        float v = -d.x * b.cs.y + d.y * b.cs.x;
        float dz = z - b.z;
        float d2 = u * u / wu2 + v * v / wv2 + dz * dz / wu2;
        float keep = sqrt(ru2 * rv2 / (wu2 * wv2));
        e += b.intensity * keep * exp(-d2) * b.colour;
    }
    float3 L = 1.0f - exp(-GG_CONTRAST * e);
    return pow(clamp(L, 1e-5f, 1.0f), GG_GAMMA);
}

/// Signed distance to a rounded rectangle, positive outside.
static float ggSD(float2 p, float2 halfSize, float radius) {
    float2 d = abs(p - halfSize) - (halfSize - radius);
    return length(max(d, float2(0.0f))) + min(max(d.x, d.y), 0.0f) - radius;
}

/// Standard normal CDF (Abramowitz-Stegun 7.1.26, |error| < 8e-8). Metal has no
/// erfc; this is the share of a Gaussian that falls inside the shape.
static float ggNormalCDF(float x) {
    float t = 1.0f / (1.0f + 0.3275911f * abs(x));
    float y = 1.0f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t + 0.254829592f) * t * exp(-x * x);
    return x >= 0.0f ? 0.5f * (1.0f + y) : 0.5f * (1.0f - y);
}

/// One pixel of GlassGlow's shade and compose passes. `size` is the view's
/// frame; the shape sits `halo` points inside it, and the halo fills the rest.
[[ stitchable ]] half4 voiceGlass(
    float2 position, half4 color,
    float2 size, float halo, float cornerRadius, float phase, float3 hues, float intensity
) {
    float2 inner = max(size - 2.0f * halo, float2(1.0f));
    float2 halfSize = inner * 0.5f;
    float height = max(inner.y, 1.0f);
    float2 local = position - float2(halo);
    float radius = clamp(cornerRadius, 0.0f, min(halfSize.x, halfSize.y));
    float sdfPx = -ggSD(local, halfSize, radius);
    float sdf = sdfPx / height;
    float aaPx = clamp(GG_EDGE_SOFTNESS * height, 0.35f, 1.0f);
    float inside = 1.0f / (1.0f + exp(-sdfPx / aaPx));
    float outside = 1.0f - inside;

    // Outward normal from the distance field's gradient: a fine sample for the
    // bevel, a coarse one (~1.5% of the box) for the rim, whose samples sit far
    // enough out that pixel steps would otherwise show.
    float h = max(3.0f, round(height * 0.0045f));
    float hc = max(1.0f, round(height * 0.015f));
    float2 g = float2(
        ggSD(local + float2(h, 0.0f), halfSize, radius) - ggSD(local - float2(h, 0.0f), halfSize, radius),
        ggSD(local + float2(0.0f, h), halfSize, radius) - ggSD(local - float2(0.0f, h), halfSize, radius));
    float2 n = float2(-g.x, g.y);
    float len = length(n);
    n = len > 1e-6f ? n / len : float2(0.0f);
    float2 gc = float2(
        ggSD(local + float2(hc, 0.0f), halfSize, radius) - ggSD(local - float2(hc, 0.0f), halfSize, radius),
        ggSD(local + float2(0.0f, hc), halfSize, radius) - ggSD(local - float2(0.0f, hc), halfSize, radius));
    float2 nc = float2(-gc.x, gc.y);
    float lc = length(nc);
    nc = lc > 1e-6f ? nc / lc : n;

    float2 p = (local - halfSize) / height;
    p.y = -p.y;
    float depth = max(sdf, 0.0f);
    float stretch = max(1.0f, max(inner.x, 1.0f) / height / GG_STRETCH_ASPECT);
    GGLight lights[10];
    ggLights(phase * 6.28318530718f, hues, lights);
    float blur2 = GG_BAND_BLUR * GG_BAND_BLUR;

    float rim = exp(-abs(sdf) / GG_RIM_WIDTH);
    float3 rimRGB = rim * (GG_RIM_AMBIENT * GG_RIM_COLOUR
                           + GG_RIM_LIGHT * ggLightField(p - nc * GG_RIM_INSET, 0.0f, stretch, blur2, lights));

    float3 glass = float3(0.0f);
    if (inside > 1e-4f) {
        // Refracted at the bevel, split per channel like a prism.
        float bev = pow(clamp(1.0f - depth / GG_BEVEL_WIDTH, 0.0f, 1.0f), GG_BEVEL_EXPONENT);
        float m[3] = { 1.0f - GG_DISPERSION, 1.0f, 1.0f + GG_DISPERSION };
        glass.r = ggLightField(p - n * (GG_BEVEL_REFRACTION * m[0] * bev), depth, stretch, 0.0f, lights).r;
        glass.g = ggLightField(p - n * (GG_BEVEL_REFRACTION * m[1] * bev), depth, stretch, 0.0f, lights).g;
        glass.b = ggLightField(p - n * (GG_BEVEL_REFRACTION * m[2] * bev), depth, stretch, 0.0f, lights).b;
        glass *= inside;
        // A hairline band just inside the edge, lit from deeper in the shape.
        // The fitted width is a fraction of the box (0.0017), which is thinner
        // than a pixel on a chip and never draws; keep at least a pixel, so the
        // outline of the shape stays visible at every phase.
        float bandWidth = max(GG_BAND_WIDTH, 1.0f / height);
        rimRGB += inside * exp(-depth / bandWidth) * GG_BAND_LIGHT
                  * ggLightField(p - nc * GG_BAND_INSET, 0.0f, stretch, blur2, lights);
    }

    // The halo: the glass blurred at three scales, spilled outside the shape.
    // GlassGlow blurs its lit-shape texture; here the light field is widened by
    // the same Gaussian (`gg_light`'s blur), and the share of the blur that
    // falls inside the shape is a normal integral over the distance field.
    float3 bloom = float3(0.0f);
    if (outside > 1e-4f) {
        for (int i = 0; i < 3; i++) {
            float sigmaPx = max(GG_BLOOM_SIGMA[i] * height, 0.3f);
            float share = ggNormalCDF(sdfPx / sigmaPx);
            if (share < 1e-3f) continue;
            bloom += GG_BLOOM_GAIN[i] * share * ggLightField(p, 0.0f, stretch, GG_BLOOM_SIGMA[i] * GG_BLOOM_SIGMA[i], lights);
        }
        // Fade the halo before the frame edge, so a halo wider than the margin
        // has no hard border.
        float border = min(min(position.x, position.y), min(size.x - position.x, size.y - position.y));
        bloom *= outside * smoothstep(0.0f, 0.12f * min(size.x, size.y), border);
    }

    // GlassGlow's compose: alpha is the brightest channel, so the colour is
    // already premultiplied; multiplying by alpha again would darken the whole
    // shape.
    float3 c = clamp((glass + rimRGB + bloom) * intensity, 0.0f, 1.0f);
    float alpha = max(c.r, max(c.g, c.b)) * color.a;
    return half4(half3(c) * color.a, half(alpha));
}
