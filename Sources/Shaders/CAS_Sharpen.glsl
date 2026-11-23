// Contrast Adaptive Sharpening (CAS) for libmpv / libplacebo
// SPDX-License-Identifier: MIT

//!HOOK LUMA
//!DESC CAS Adaptive Sharpen
//!BIND LUMA

#define CAS_SHARPNESS 0.45

vec4 hook() {
    float e = LUMA_texOff(vec2( 0.0,  0.0)).x;
    float a = LUMA_texOff(vec2(-1.0, -1.0)).x;
    float b = LUMA_texOff(vec2( 0.0, -1.0)).x;
    float c = LUMA_texOff(vec2( 1.0, -1.0)).x;
    float d = LUMA_texOff(vec2(-1.0,  0.0)).x;
    float f = LUMA_texOff(vec2( 1.0,  0.0)).x;
    float g = LUMA_texOff(vec2(-1.0,  1.0)).x;
    float h = LUMA_texOff(vec2( 0.0,  1.0)).x;
    float i = LUMA_texOff(vec2( 1.0,  1.0)).x;

    float mn = min(min(min(d, e), min(f, b)), h);
    float mn2 = min(mn, min(min(a, c), min(g, i)));
    mn += mn2;

    float mx = max(max(max(d, e), max(f, b)), h);
    float mx2 = max(mx, max(max(a, c), max(g, i)));
    mx += mx2;

    float rcpMx = 1.0 / max(mx, 1e-5);
    float amp = clamp(min(mn, 2.0 - mx) * rcpMx, 0.0, 1.0);
    amp = sqrt(amp);

    float peak = -1.0 / mix(8.0, 5.0, CAS_SHARPNESS);
    float w = amp * peak;
    float rcpWeight = 1.0 / (1.0 + 4.0 * w);

    float outLuma = clamp(((b + d + f + h) * w + e) * rcpWeight, 0.0, 1.0);
    return vec4(outLuma, 0.0, 0.0, 1.0);
}
