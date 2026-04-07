#include "ReShade.fxh"

// ============================================================================
// UI ПАРАМЕТРЫ / UI PARAMETERS
// ============================================================================

uniform int DEBUG_MODE <
    ui_type = "combo";
    ui_label = "Режим отладки | Debug Mode";
    ui_items = "Отключено | Disabled\0Оригинальное AO | Original AO\0Размытое AO | Blurred AO\0Маска прозрачности | Transparency Mask\0Маска яркости | Brightness Mask\0Финальный результат | Final Result\0";
    ui_tooltip = "Выберите режим визуализации для отладки | Select visualization mode for debugging";
> = 0;

uniform float AO_BLUR_STRENGTH <
    ui_type = "slider";
    ui_label = "Сила размытия AO | AO Blur Strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Размывает AO для соответствия прозрачным объектам | Blurs AO to match transparent objects";
> = 0.5;

uniform float BLUR_RADIUS <
    ui_type = "slider";
    ui_label = "Радиус размытия | Blur Radius";
    ui_min = 1.0;
    ui_max = 16.0;
    ui_step = 0.5;
    ui_tooltip = "Увеличивайте для более мягкого размытия | Increase for softer blur";
> = 4.0;

uniform float BRIGHTNESS_THRESHOLD <
    ui_type = "slider";
    ui_label = "Порог яркости | Brightness Threshold";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "AO ослабляется на ярких участках (GodRays, свет) | AO weakens on bright areas";
> = 0.6;

uniform float BRIGHTNESS_FALLOFF <
    ui_type = "slider";
    ui_label = "Мягкость переходов яркости | Brightness Falloff";
    ui_min = 0.1;
    ui_max = 2.0;
    ui_step = 0.1;
    ui_tooltip = "Контролирует мягкость перехода между светлыми и тёмными зонами | Controls transition softness";
> = 0.5;

uniform float DEPTH_MASK_STRENGTH <
    ui_type = "slider";
    ui_label = "Сила маски глубины | Depth Mask Strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Ослабляет AO на объектах за прозрачными эффектами | Weakens AO on objects behind transparent effects";
> = 0.7;

uniform float DEPTH_FADE_RANGE <
    ui_type = "slider";
    ui_label = "Диапазон глубины | Depth Fade Range";
    ui_min = 0.01;
    ui_max = 0.5;
    ui_step = 0.01;
    ui_tooltip = "Насколько далеко от камеры применяется коррекция | How far from camera correction applies";
> = 0.1;

uniform float TRANSPARENCY_DETECTION <
    ui_type = "slider";
    ui_label = "Чувствительность прозрачности | Transparency Sensitivity";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Определяет, как сильно резкие переходы обрабатываются как прозрачные объекты | How sharp transitions are treated as transparency";
> = 0.6;

uniform float FINAL_AO_STRENGTH <
    ui_type = "slider";
    ui_label = "Финальная сила AO | Final AO Strength";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
    ui_tooltip = "Общая интенсивность скорректированного AO | Overall intensity of corrected AO";
> = 0.85;

// ============================================================================
// ТЕКСТУРЫ И СЭМПЛЕРЫ / TEXTURES AND SAMPLERS
// ============================================================================

texture BackBuffer : COLOR;
texture DepthBuffer : DEPTH;

sampler sBackBuffer {
    Texture = BackBuffer;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = LINEAR;
};

sampler sDepth {
    Texture = DepthBuffer;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

// ============================================================================
// ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ / HELPER FUNCTIONS
// ============================================================================

// Преобразование глубины в линейное пространство
float GetLinearDepth(float2 uv) {
    float depth = tex2D(sDepth, uv).x;
    float linearDepth = ReShade::GetLinearizedDepth(uv);
    return linearDepth;
}

// Получение локального контраста (для обнаружения прозрачных объектов)
float GetLocalContrast(float2 uv, float radius) {
    float center = tex2D(sBackBuffer, uv).r * 0.299 + tex2D(sBackBuffer, uv).g * 0.587 + tex2D(sBackBuffer, uv).b * 0.114;
    
    float sum = 0.0;
    int samples = 8;
    
    for(int i = 0; i < samples; i++) {
        float angle = (6.28318530718 * i) / samples;
        float2 offset = float2(cos(angle), sin(angle)) * radius / BUFFER_HEIGHT;
        
        float3 col = tex2D(sBackBuffer, uv + offset).rgb;
        float lum = col.r * 0.299 + col.g * 0.587 + col.b * 0.114;
        sum += abs(lum - center);
    }
    
    return sum / samples;
}

// Получение яркости пикселя
float GetBrightness(float3 col) {
    return col.r * 0.299 + col.g * 0.587 + col.b * 0.114;
}

// Простое гауссовское размытие
float GetBlurredAO(float2 uv, float radius) {
    float3 aoColor = tex2D(sBackBuffer, uv).rgb;
    float ao = GetBrightness(aoColor);
    
    float sum = ao;
    float weights = 1.0;
    
    int samples = int(radius) * 2;
    
    for(int i = -samples; i <= samples; i++) {
        for(int j = -samples; j <= samples; j++) {
            if(i == 0 && j == 0) continue;
            
            float2 offset = float2(i, j) / BUFFER_HEIGHT * radius;
            float3 sampleCol = tex2D(sBackBuffer, uv + offset).rgb;
            float sampleAO = GetBrightness(sampleCol);
            
            float dist = length(float2(i, j));
            float weight = exp(-(dist * dist) / (2.0 * radius * radius));
            
            sum += sampleAO * weight;
            weights += weight;
        }
    }
    
    return sum / weights;
}

// ============================================================================
// ОСНОВНЫЕ ШЕЙДЕРЫ / MAIN SHADERS
// ============================================================================

float4 PS_SSAO_Fix(float4 position : SV_POSITION, float2 texcoord : TEXCOORD0) : SV_TARGET {
    float3 original = tex2D(sBackBuffer, texcoord).rgb;
    float originalAO = GetBrightness(original);
    
    // Получаем маску яркости (для GodRays и светлых эффектов)
    float brightness = GetBrightness(original);
    float brightnessMask = pow(max(brightness - BRIGHTNESS_THRESHOLD, 0.0) / (1.0 - BRIGHTNESS_THRESHOLD + 0.001), BRIGHTNESS_FALLOFF);
    brightnessMask = saturate(brightnessMask);
    
    // Получаем маску локального контраста (для обнаружения прозрачных объектов)
    float contrast = GetLocalContrast(texcoord, 2.0);
    float transparencyMask = saturate(contrast * TRANSPARENCY_DETECTION);
    
    // Получаем маску глубины
    float depth = GetLinearDepth(texcoord);
    float depthMask = saturate(1.0 - (depth / DEPTH_FADE_RANGE)) * DEPTH_MASK_STRENGTH;
    
    // Комбинируем маски
    float combinedMask = max(brightnessMask, max(transparencyMask, depthMask));
    
    // Размываем AO, если нужно
    float blurredAO = GetBlurredAO(texcoord, BLUR_RADIUS);
    
    // Интерполируем между оригинальным и размытым AO на основе масок
    float correctedAO = mix(originalAO, blurredAO, AO_BLUR_STRENGTH * combinedMask);
    
    // Применяем финальную силу
    float finalAO = lerp(1.0, correctedAO, FINAL_AO_STRENGTH);
    
    // DEBUG MODE
    if(DEBUG_MODE == 1) {
        return float4(originalAO, originalAO, originalAO, 1.0); // Оригинальное AO
    }
    else if(DEBUG_MODE == 2) {
        return float4(blurredAO, blurredAO, blurredAO, 1.0); // Размытое AO
    }
    else if(DEBUG_MODE == 3) {
        return float4(transparencyMask, transparencyMask, transparencyMask, 1.0); // Маска прозрачности
    }
    else if(DEBUG_MODE == 4) {
        return float4(brightnessMask, brightnessMask, brightnessMask, 1.0); // Маска яркости
    }
    else if(DEBUG_MODE == 5) {
        return float4(combinedMask, combinedMask, combinedMask, 1.0); // Финальная маска
    }
    else if(DEBUG_MODE == 6) {
        return float4(finalAO, finalAO, finalAO, 1.0); // Финальный результат
    }
    
    // Применяем коррекцию к оригинальному цвету
    float3 corrected = original * (finalAO / max(originalAO, 0.001));
    
    return float4(corrected, 1.0);
}

// ============================================================================
// ТЕХНИКИ / TECHNIQUES
// ============================================================================

technique AO_Transparency_Fix {
    pass {
        VertexShader = PostProcessVS;
        PixelShader = PS_SSAO_Fix;
    }
}