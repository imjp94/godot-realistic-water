/*
Realistic Water Shader for GODOT 3.1.1

Copyright (c) 2019 UnionBytes, Achim Menzel (alias AiYori)

Permission is hereby granted, free of charge, to any person obtaining a copy of this 
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
OR OTHER DEALINGS IN THE SOFTWARE.

-- UnionBytes <https://www.unionbytes.de/>
-- YouTube: <https://www.youtube.com/user/UnionBytes>
*/


// For this shader min. GODOT 3.1.1 is required, because 3.1 has a depth buffer bug!
shader_type 	spatial;
render_mode 	cull_back,diffuse_burley,specular_schlick_ggx, blend_mix;


// Wave settings:
uniform float	wave_speed		 = 0.5; // Speed scale for the waves
uniform float wave_a_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec4	wave_a			 = vec4(1.0, 1.0, 0.35, 3.0); 	// xy = Direction, z = Steepness, w = Length
uniform float wave_b_strength : hint_range(0.0, 1.0) = 1.0;
uniform	vec4	wave_b			 = vec4(1.0, 0.6, 0.30, 1.55);	// xy = Direction, z = Steepness, w = Length
uniform float wave_c_strength : hint_range(0.0, 1.0) = 1.0;
uniform	vec4	wave_c			 = vec4(1.0, 1.3, 0.25, 0.9); 	// xy = Direction, z = Steepness, w = Length

// Surface settings:
uniform sampler2D depth_gradient : hint_albedo;					// Color based on depth
uniform vec2 	sampler_scale 	 = vec2(0.25, 0.25); 			// Scale for the sampler
uniform vec2	sampler_direction= vec2(0.05, 0.04); 			// Direction and speed for the sampler offset

uniform sampler2D uv_sampler : hint_aniso; 						// UV motion sampler for shifting the normalmap
uniform vec2 	uv_sampler_scale = vec2(0.25, 0.25); 			// UV sampler scale
uniform float 	uv_sampler_strength = 0.04; 					// UV shifting strength

uniform sampler2D normalmap_a_sampler : hint_normal;			// Normalmap sampler A
uniform sampler2D normalmap_b_sampler : hint_normal;			// Normalmap sampler B
uniform float normalmap_depth = 1.0;

uniform sampler2D foam_sampler : hint_black;					// Foam sampler
uniform vec2 foam_sampler_uv_scale = vec2(1.0, 1.0);			// Foam sampler uv scale
uniform float foam_level : hint_range(0.0, 1.0) = 1.0;			// Foam level -> distance from the object (0.0 - 0.5)
uniform float foam_cutoff : hint_range(0.0, 1.0) = 0.0;			// Smooth transition at edge
uniform float foam_strength = 1.0;								// Strength of Foam
uniform float roughness : hint_range(0.0, 1.0) = 0.2;
uniform float specular : hint_range(0.0, 1.0) = 0.2;
uniform float rim : hint_range(0.0, 1.0) = 0.0;
uniform float rim_tint : hint_range(0.0, 1.0) = 0.0;

// Volume settings:
uniform float 	refraction 		 = 0.075;						// Refraction of the water

uniform float density = 1.0;									// Beers law value, regulates the blending size to the deep water level
uniform float clarity = 0.0;									// Clarity of water at "shallow" water level
uniform float opacity : hint_range(0.0, 1.0) = 1.0;				// Strength of water color(depth_gradient), 0 as transparent
uniform float fresnel_power = 0.0;								// Transmission of light based on view angle
uniform float depth_offset	 = 0.0;								// Offset for the blending

// Projector for the water caustics:
uniform mat4	projector;										// Projector matrix, mostly the matric of the sun / directlight
uniform vec4 caustic_color : hint_color = vec4(1.0);			// Color for the caustic
uniform sampler2DArray caustic_sampler : hint_black;			// Caustic sampler, (Texture array with 16 Textures for the animation)
uniform vec2 caustic_sampler_uv_scale = vec2(1.0, 1.0);			// Caustic sample uv scale
uniform float caustic_strength = 0.0;							// Brightness of caustic
uniform float caustic_depth_fade = 1.0;							// Fading of caustice based on depth

// Vertex -> Fragment:
varying float 	vertex_height;									// Height of the water surface
varying vec3 	vertex_normal;									// Vertex normal -> Needed for refraction calculation
varying vec3 	vertex_binormal;								// Vertex binormal -> Needed for refraction calculation
varying vec3 	vertex_tangent;									// Vertex tangent -> Needed for refraction calculation

varying mat4 	inv_mvp; 										// Inverse ModelViewProjection matrix -> Needed for caustic projection


// Wave function:
vec4 wave(vec4 parameter, vec2 position, float time, inout vec3 tangent, inout vec3 binormal)
{
	float	wave_steepness	 = parameter.z;
	float	wave_length		 = parameter.w;

	float	k				 = 2.0 * 3.14159265359 / wave_length;
	float 	c 				 = sqrt(9.8 / k);
	vec2	d				 = normalize(parameter.xy);
	float 	f 				 = k * (dot(d, position) - c * time);
	float 	a				 = wave_steepness / k;
	
			tangent			+= normalize(vec3(1.0-d.x * d.x * (wave_steepness * sin(f)), d.x * (wave_steepness * cos(f)), -d.x * d.y * (wave_steepness * sin(f))));
			binormal		+= normalize(vec3(-d.x * d.y * (wave_steepness * sin(f)), d.y * (wave_steepness * cos(f)), 1.0-d.y * d.y * (wave_steepness * sin(f))));

	return vec4(d.x * (a * cos(f)), a * sin(f) * 0.25, d.y * (a * cos(f)), 0.0);
}

// Vertex shader:
void vertex()
{
	float	time			 = TIME * wave_speed;
	
	vec4	vertex			 = vec4(VERTEX, 1.0);
	vec3	vertex_position  = (WORLD_MATRIX * vertex).xyz;
	
			vertex_tangent 	 = vec3(0.0, 0.0, 0.0);
		 	vertex_binormal  = vec3(0.0, 0.0, 0.0);
	
			vertex 			+= wave(wave_a * clamp(wave_a_strength, 0.01, 1.0), vertex_position.xz, time, vertex_tangent, vertex_binormal);
			vertex 			+= wave(wave_b * clamp(wave_b_strength, 0.01, 1.0), vertex_position.xz, time, vertex_tangent, vertex_binormal);
			vertex 			+= wave(wave_c * clamp(wave_c_strength, 0.01, 1.0), vertex_position.xz, time, vertex_tangent, vertex_binormal);
	
			vertex_position  = vertex.xyz;
	
			vertex_height	 = (PROJECTION_MATRIX * MODELVIEW_MATRIX * vertex).z;
	
			TANGENT			 = vertex_tangent;
			BINORMAL		 = vertex_binormal;
			vertex_normal	 = normalize(cross(vertex_binormal, vertex_tangent));
			NORMAL			 = vertex_normal;
		
			UV				 = vertex.xz * sampler_scale;
	
			VERTEX			 = vertex.xyz;
			
			inv_mvp = inverse(PROJECTION_MATRIX * MODELVIEW_MATRIX);
}


// Fragment shader:
void fragment()
{
	// Calculation of the UV with the UV motion sampler
	vec2	uv_offset 					 = sampler_direction * TIME;
	vec2 	uv_sampler_uv 				 = UV * uv_sampler_scale + uv_offset;
	vec2	uv_sampler_uv_offset 		 = uv_sampler_strength * texture(uv_sampler, uv_sampler_uv).rg * 2.0 - 1.0;
	vec2 	uv 							 = UV + uv_sampler_uv_offset;

	// Normalmap:
	vec3 	normalmap					 = texture(normalmap_a_sampler, uv - uv_offset*2.0).rgb * 0.75;		// 75 % sampler A
			normalmap 					+= texture(normalmap_b_sampler, uv + uv_offset).rgb * 0.25;			// 25 % sampler B
	
	// Refraction UV:
	vec3	ref_normalmap				 = normalmap * 2.0 - 1.0;
			ref_normalmap				 = normalize(vertex_tangent*ref_normalmap.x + vertex_binormal*ref_normalmap.y + vertex_normal*ref_normalmap.z);
	vec2 	ref_uv						 = SCREEN_UV + (ref_normalmap.xy * refraction) / vertex_height;

	// Ground depth:
	float fresnel = sqrt(1.0 - dot(NORMAL, VIEW));
	fresnel = pow(fresnel, fresnel_power);

	float 	depth_raw					 = texture(DEPTH_TEXTURE, ref_uv).r * 2.0 - 1.0;
	float	depth						 = PROJECTION_MATRIX[3][2] / (depth_raw + PROJECTION_MATRIX[2][2]);
			
	float 	depth_blend 				 = exp((depth+VERTEX.z + depth_offset) * -density);
			depth_blend 				 = clamp((1.0-depth_blend) * fresnel, 0.0, 1.0);	
	float	depth_blend_pow				 = clamp(pow(depth_blend, clarity), 0.0, 1.0);

	// Ground color:
	vec3 	screen_color 				 = textureLod(SCREEN_TEXTURE, ref_uv, depth_blend_pow).rgb;
	vec3 	dye_color = texture(depth_gradient, vec2(depth_blend, UV.x)).rgb;
	vec3	color = mix(screen_color, dye_color, clamp(depth_blend_pow * opacity, 0.0, 1.0));

	// Caustic screen projection
	vec4 	caustic_screenPos 			 = vec4(ref_uv*2.0-1.0, depth_raw, 1.0);
	vec4 	caustic_localPos 			 = inv_mvp * caustic_screenPos;
			caustic_localPos			 = vec4(caustic_localPos.xyz/caustic_localPos.w, caustic_localPos.w);
	
	vec2 	caustic_Uv 					 = (caustic_localPos.xz / vec2(1024.0) + 0.5) * caustic_sampler_uv_scale;
	vec4 	caustic_projection			 = texture(caustic_sampler, vec3(caustic_Uv, mod(TIME*14.0, 16.0)));
	vec3	caustic				 		 = (caustic_projection.rgb * clamp(opacity * 1.0-depth_blend, 0.0, 1.0) * pow((1.0 - depth_blend), caustic_depth_fade)) * caustic_strength;

			color 						 = mix(color, caustic_color.rgb, vec3(caustic.r) * clamp(opacity * 1.0-depth_blend, 0.0, 1.0) * pow((1.0 - depth_blend), caustic_depth_fade));

	// Foam:
			if(depth + VERTEX.z < foam_level && depth > vertex_height-0.1)
			{
				float foam = clamp(texture(foam_sampler, (uv * foam_sampler_uv_scale) - uv_offset).r, 0.0, 1.0);
				foam *= foam_strength * smoothstep(foam_cutoff, 1.0, clamp((1.0-(depth + VERTEX.z)), 0.0, 1.0));
				color = mix(color, vec3(1.0), foam);
			}

	// Set all values:
	ALBEDO = color;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	EMISSION = caustic_color.rgb * caustic;
	RIM = rim;
	RIM_TINT = rim_tint;
	NORMALMAP = normalmap;
	NORMALMAP_DEPTH = normalmap_depth;
}