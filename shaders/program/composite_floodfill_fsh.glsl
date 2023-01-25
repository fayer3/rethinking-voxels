// propagate blocklight data


#include "/lib/common.glsl"

in vec2 texCoord;
#ifndef COLORTEX8
#define COLORTEX8
uniform sampler2D colortex8;
#endif
#ifndef COLORTEX9
#define COLORTEX9
uniform sampler2D colortex9;
#endif
#if (defined DISTANCE_FIELD || WATER_STYLE >= 4) && !defined COLORTEX11
#define COLORTEX11
uniform sampler2D colortex11;
#endif
#ifndef SHADOWCOL0
#define SHADOWCOL0
uniform sampler2D shadowcolor0;
#endif
#ifndef SHADOWCOL1
#define SHADOWCOL1
uniform sampler2D shadowcolor1;
#endif
uniform sampler2D colortex15; // texture atlas
ivec2 atlasSize = textureSize(colortex15, 0);
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

#if WATER_STYLE >= 4
	uniform sampler2D noisetex;
	uniform float frameTimeCounter;
	uniform float frameTime;
	#define WATERHEIGHT
	#include "/lib/util/noise.glsl"
	#undef WATERHEIGHT
#endif

#include "/lib/vx/voxelMapping.glsl"
#include "/lib/vx/voxelReading.glsl"

ivec3[7] offsets = ivec3[7](ivec3(0), ivec3(-1, 0, 0), ivec3(0, -1, 0), ivec3(0, 0, -1), ivec3(1, 0, 0), ivec3(0, 1, 0), ivec3(0, 0, 1));

/*
flood fill data:
 - colortex8:
	r: material hash, changed
	g: visibilities of light sources at different levels of detail
	b: position of light source 1 x, y
	a: position of light source 1 z, intensity
 - colortex9:
	r: position of light source 2 x, y
	g: position of light source 2 z, intensity
	b: position of light source 3 x, y
	a: position of light source 3 z, intensity
 - colortex10:
	r: compressed colour data of sun shadow map
	g: opaque shadow depth
	b: transparent shadow depth
	a: height map (last 8 bits free)
 - colortex11:
	r: distance field, water height
	g: wave simulation position
	b: wave simulation velocity
	a: free
*/

void main() {
	vec2 debugData = vec2(0);
	vec2 tex8size = vec2(textureSize(colortex8, 0));
	ivec2 pixelCoord = ivec2(texCoord * tex8size);
	ivec4 dataToWrite0;
	ivec4 dataToWrite1;
	ivec4 dataToWrite3 = ivec4(255, 0, 0, 0);
	//if (max(pixelCoord.x, pixelCoord.y) < shadowMapResolution) {
		vxData blockData = readVxMap(pixelCoord);
		vec3 pos = getVxPos(pixelCoord);
		vec3 oldPos = pos + (floor(cameraPosition) - floor(previousCameraPosition));
		bool previouslyInRange = length(oldPos - pos) > 0.5 ? isInRange(oldPos, 1) : true;
		ivec4[7] aroundData0;
		ivec4[7] aroundData1;
#if defined ADVANCED_LIGHT_TRACING || defined DISTANCE_FIELD
		int changed;
		if (previouslyInRange) {
			ivec2 oldCoords = getVxPixelCoords(oldPos);
			aroundData0[0] = ivec4(texelFetch(colortex8, oldCoords, 0) * 65535 + 0.5);
			aroundData1[0] = ivec4(texelFetch(colortex9, oldCoords, 0) * 65535 + 0.5);
			int prevchanged = aroundData0[0].x % 256;
			changed = (prevchanged == 0) ? 0 : max(prevchanged - 1, 1); // need to update if voxel is new
		} else changed = 1;
		// newhash and mathash are hashes of the material ID, which change if the block at the given location changes, so it can be detected
		int newhash =  blockData.mat > 0 ? blockData.mat % 255 + 1 : 0;
		int mathash = previouslyInRange ? aroundData0[0].x >> 8 : 0;
		// if the material changed, then propagate that
		if (mathash != newhash) {
			// the change will not have any effects if it occurs further away than the light level at its location, because any light that passes through that location has faded out by then
			changed = blockData.emissive ? blockData.lightlevel : aroundData0[0].w >> 8;
			mathash = newhash;
		}
		if (mathash != 0) dataToWrite3.x = 0;
		//check for changes in surrounding voxels and propagate them
#endif
		for (int k = 1; k < 7; k++) {
			vec3 aroundPos = oldPos + offsets[k];
			ivec2 aroundCoords = getVxPixelCoords(aroundPos);
			if (isInRange(aroundPos)) {
				aroundData0[k] = ivec4(texelFetch(colortex8, aroundCoords, 0) * 65535 + 0.5);
				aroundData1[k] = ivec4(texelFetch(colortex9, aroundCoords, 0) * 65535 + 0.5);
				#ifdef DISTANCE_FIELD
					if (mathash == 0) {
						ivec4 aroundData3 = ivec4(texelFetch(colortex11, aroundCoords, 0) * 65535 + 0.5);
						dataToWrite3.x = min(dataToWrite3.x, aroundData3.x % 256 + 1);
					}
				#endif
#if ADVANCED_LIGHT_TRACING > 0
				int aroundChanged = aroundData0[k].x % 256;
				changed = max(aroundChanged - 1, changed);
			} else {
				aroundData0[k] = ivec4(0);
				aroundData1[k] = ivec4(0);
#else
			} else {
				aroundData0[k] = ivec4(0, 0, 0, 127);
				aroundData1[k] = ivec4(0, 0, 0, 127);
#endif
			}
		}
#if ADVANCED_LIGHT_TRACING > 0
		// copy data so it is written back to the buffer if unchanged
		dataToWrite0.xzw = aroundData0[0].xzw;
		dataToWrite0.y = int(texelFetch(colortex8, getVxPixelCoords(pos), 0).y * 65535 + 0.5);
		dataToWrite1 = aroundData1[0];
		dataToWrite0.x = changed + 256 * mathash;
		if (changed > 0) {
			// sources will contain nearby light sources, sorted by intensity
			ivec4 sources[3] = ivec4[3](
				ivec4(0),
				ivec4(0),
				ivec4(0)
			);
			if (blockData.emissive) {
				sources[0] = ivec4(128, 128, 128, blockData.lightlevel);
//				dataToWrite0.y = 60000;
			}
			for (int k = 1; k < 7; k++) {
				// current surrounding (sorted but still compressed) light data
				ivec2[3] theselights = ivec2[3](aroundData0[k].zw, aroundData1[k].xy, aroundData1[k].zw);
				for (int i = 0; i < 3; i++) {
					//unpack and adjust light data
					ivec4 thisLight = ivec4(theselights[i].x % 256, theselights[i].x >> 8, theselights[i].y % 256, theselights[i].y >> 8);
					thisLight.xyz += offsets[k];
					vxData thisLightData = readVxMap(getVxPixelCoords(pos + thisLight.xyz - vec3(128.0)));
					thisLight.w = (aroundData0[k].y >> i) % 2 == 1 ? thisLight.w - 1 : min(thisLight.w - 1, 1);
					if (!thisLightData.emissive || thisLight.w <= 0) break; // ignore light sources with zero intensity
					bool newLight = true;
					for (int j = 0; j < 3; j++) {
					// check if light source is already registered
						if (length(vec3(thisLight.xyz - sources[j].xyz)) < 0.2) {
							newLight = false;
							if (j > 0 && sources[j-1].w < thisLight.w) {
								sources[j] = sources[j-1];
								sources[j-1] = thisLight;
							}
							else if (sources[j].w < thisLight.w) sources[j] = thisLight;
							break;
						}
					}
					if (newLight) {
						// sort by intensity, to keep the brightest light sources
						int j = 3;
						while (j > 0 && thisLight.w >= sources[j - 1].w) j--;
						for (int l = 1; l >= j; l--) sources[l + 1] = sources[l];
						if (j < 3) sources[j] = thisLight;
					}
				}
			}
			// write new light data
			dataToWrite0.zw = ivec2(
				sources[0].x + (sources[0].y << 8),
				sources[0].z + (sources[0].w << 8));
			dataToWrite1 = ivec4(
				sources[1].x + (sources[1].y << 8),
				sources[1].z + (sources[1].w << 8),
				sources[2].x + (sources[2].y << 8),
				sources[2].z + (sources[2].w << 8));
		}
#else
		vec3 colMult = vec3(1);
		if (blockData.emissive || !blockData.trace || blockData.crossmodel) dataToWrite0.w = 127;
		else if (blockData.full) {
			if (blockData.alphatest) {
			vec4 texCol = texture2DLod(colortex15, blockData.texcoord, 0);
			   if (texCol.a < 0.2) {
					dataToWrite0.w = 127;
				} else if (texCol.a < 0.8) {
					dataToWrite0.w = 127;
					texCol.a = pow(texCol.a, TRANSLUCENT_LIGHT_TINT);
					texCol.rgb /= max(max(0.0001, texCol.r), max(texCol.g, texCol.b));
					texCol.rgb *= 0.5 + TRANSLUCENT_LIGHT_CONDUCTION / (texCol.r + texCol.g + texCol.b);
					colMult = clamp(1 - texCol.a + texCol.a * texCol.rgb, vec3(0), vec3(max(1.0, TRANSLUCENT_LIGHT_CONDUCTION + 0.02)));
				} else dataToWrite0.w = 0;
			} else dataToWrite0.w = 0;
		} else if (blockData.cuboid) {
			dataToWrite0.w = 0;
			for (int k = 1; k < 7; k++) {
				if ((blockData.lower[(k-1)%3] < 0.02 && k < 4) || (blockData.upper[(k-1)%3] > 0.98 && k >= 4)) {
					bool seals = true;
					for (int i = (k+3)%3; i != (k+2)%3; i = (i+1)%3) {
						if (blockData.lower[i] > 0.02 || blockData.upper[i] < 0.98) seals = false;
					}
					if (!seals) dataToWrite0.w += 1<<(k-1);
				} else dataToWrite0.w += 1<<(k-1);
			}
		} else dataToWrite0.w = 127;
		if (!blockData.emissive) {
			vec3 col = vec3(0);
			float propSum = 0.0001;
			for (int k = 1; k < 7; k++) {
				int propData = ((aroundData0[k].w >> ((k+2)%6))%2) * ((dataToWrite0.w >> ((k-1)%6))%2);
				vec3 col0 = vec3(aroundData0[k].xyz * propData) / 65535;
				col += col0 * col0;
				propSum += propData;
			}
			col /= mix(propSum, 6.0, BFF_ABSORBTION_AMOUNT);
			col = colMult * sqrt(col);
			col *= FF_PROP_MUL * max(0.0, (length(col) - FF_PROP_SUB) / (length(col) + 0.0001));
			//if (length(col) > 5) col = vec3(0);
			dataToWrite0.xyz = ivec3(col * 65535.0);
		} else dataToWrite0.xyz = ivec3(65535.0 / 700.0 * blockData.lightcol * blockData.lightlevel * blockData.lightlevel);
#endif
	#if WATER_STYLE >= 4
	#define WAVEHEIGHT 5.0
		if (max(pixelCoord.x, pixelCoord.y) < SHADOWRES / VXHEIGHT) {
			int height0 = -128;
			for (int height = min(VXHEIGHT * VXHEIGHT / 2 - 1, 127); height > max(- VXHEIGHT * VXHEIGHT / 2, -128); height--) {
				vxData blockData = readVxMap(getVxPixelCoords(ivec3(pixelCoord - vxRange / 2, height).xzy));
				if (blockData.mat == 31000) {
					height0 = height;
					break;
				} else if (blockData.entity) {
					height0 = height;
				}
			}
			dataToWrite3.x += 256 * (height0 + 128);
		}
		ivec2 oldCoord = pixelCoord + VXHEIGHT * ivec2(1.001 * (floor(cameraPosition) - floor(previousCameraPosition)).xz);
		int hasWater = int(texelFetch(colortex11, oldCoord / VXHEIGHT, 0).x * 65535 + 0.5) >> 8;
		if (true || hasWater != 0) {
			vec2 state = (texelFetch(colortex11, oldCoord, 0).yz * 2 - 1) * WAVEHEIGHT;
			if (dot(state + vec2(WAVEHEIGHT), vec2(1)) < 0.01) state = vec2(0);
			float a = 0;
			for (int x = -1; x < 2; x += 2) {
				for (int z = -1; z < 2; z += 2) {
					ivec2 aroundCoord = clamp(oldCoord + ivec2(x, z), ivec2(1, 0), ivec2(SHADOWRES - 1));
					int aroundWater = int(aroundCoord - oldCoord == ivec2(x, z)) * (int(texelFetch(colortex11, aroundCoord / VXHEIGHT, 0).x * 65535 + 0.5) >> 8);
					vec4 aroundData = texelFetch(colortex11, aroundCoord, 0);
					vec2 aroundState = (aroundData.yz * 2.0 - 1.0) * WAVEHEIGHT;
					a += (aroundState.x - state.x) * float(aroundWater != 0 && abs(aroundWater - hasWater) < 4);
				}
			}
			state.y += a * min(frameTime * 10, 0.7) / 4.0;
			vec3 waterPos = vec3(pixelCoord.x - SHADOWRES / 2, VXHEIGHT * (hasWater - 127), pixelCoord.y - SHADOWRES / 2) / VXHEIGHT;
			if (hasWater > 0) {
				for (int i = -1; i < 2; i++) {
					if (readVxMap(getVxPixelCoords(waterPos + vec3(0, i, 0))).entity) {
						state.y = mix(state.y, 0.2 * sin(frameTimeCounter * 4), 0.1);
						break;
					}
				}
			}
			if (length(waterPos) < 1) {
				state.y = mix(state.y, 1.5 * dot(waterPos - fract(cameraPosition), cameraPosition - previousCameraPosition), 0.2);
			}
			vec2 wind = vec2(frameTimeCounter * 0.016, 0.0);
			vec2 waterPos2 = (waterPos.xz + cameraPosition.xz) * 0.3 / 89.286;
			state.x = mix(state.x, 0.2 + 0.2 * GetWaterHeightMap(waterPos2, vec3(0), wind), 0.1);
			state.x += state.y;
			state *= 0.9997 - 0.1 * float(hasWater == 0);
			dataToWrite3.yz = ivec2(65535 * (state / WAVEHEIGHT * 0.5 + 0.5) + 0.5);
		} else {
			ivec2 oldState = ivec2(texelFetch(colortex11, oldCoord, 0).yz * 65535 + 0.5);
			if (oldState.x > 0 && oldState.y > 0) dataToWrite3.yz = oldState;
			else dataToWrite3.yz = ivec2(32768);
		}
	#endif
	//}
	/*RENDERTARGETS:8,9,11*/
	gl_FragData[0] = vec4(dataToWrite0) / 65535.0;
	gl_FragData[1] = vec4(dataToWrite1) / 65535.0;
	gl_FragData[2] = vec4(dataToWrite3) / 65535.0;

}