package lime.tools;

import hxp.Haxelib;
import hxp.Log;
import hxp.Path;
import hxp.System;
import lime.graphics.Image;
import lime.graphics.ImageFileFormat;
import lime.graphics.PixelFormat;
import lime.tools.Asset;
import lime.tools.HXProject;
import sys.io.File;
import sys.FileSystem;

class ASTCTextureHelper
{
	private static var checkedEncoder:Bool = false;
	private static var encoderPath:String = null;
	private static var compressorAvailable:Null<Bool> = null;
	private static var missingWarned:Bool = false;
	private static var converted:Int = 0;
	private static var skipped:Int = 0;
	private static var failed:Int = 0;
	private static var strippedPNG:Int = 0;
	private static var strippedPNGAssets:Array<Asset> = [];
	private static var checkedEncoder:Bool = false;
    private static var encoderPath:String = null;
    private static var compressorAvailable:Null<Bool> = null;
    private static var compressionExcludes:Array<String> = null;

	public static function prepareProjectAssets(project:HXProject, targetDirectory:String):Void
	{
		converted = 0;
		skipped = 0;
		failed = 0;
		strippedPNG = 0;
		strippedPNGAssets = [];
		ensureCompressionExcludes(project);

		if (!isEnabled(project))
			return;

		Log.info("", " - \x1b[1mASTC texture conversion enabled:\x1b[0m block=" + getBlockSize(project)
			+ " quality=" + getQuality(project) + " colorprofile=" + getColorProfile(project)
			+ " premultiplyAlpha=" + getPremultiplyAlpha(project)
			+ " smartBlocks=" + getSmartBlocks(project) + " detailBlock=" + getDetailBlockSize(project)
			+ " largeBlock=" + getLargeBlockSize(project) + " hugeBlock=" + getHugeBlockSize(project)
			+ " strict=" + getStrict(project));

		if (!hasEncoder())
		{
			if (getStrict(project))
				Log.error("ASTC strict mode is enabled but no ASTC encoder was found. Install `astc-compressor` or set ASTC_ENCODER.");
			warnMissingEncoder();
			return;
		}

		var astcCache = Path.combine(targetDirectory, "obj/astc-assets");
		var existing:Map<String, Bool> = [];
		for (asset in project.assets)
			existing.set(asset.resourceName, true);

		var stripPNG = project.config.getBool("android.astc-strip-png", true);
		var strict = getStrict(project);
		var finalAssets:Array<Asset> = [];
		for (asset in project.assets)
		{
			if (shouldExcludeCompression(asset))
            {
            	Log.info("", " - ASTC excluded: " + asset.resourceName);
            	finalAssets.push(asset);
            	continue;
            }
			
			if (!isPNGAsset(asset, asset.resourceName))
			{
				finalAssets.push(asset);
				continue;
			}

			if (asset.sourcePath == null || asset.sourcePath == "")
			{
				if (strict)
					Log.error("ASTC strict mode cannot convert PNG asset without a source path: " + asset.resourceName);
				finalAssets.push(asset);
				continue;
			}

			var resourceName = replaceExtension(asset.resourceName, "astc");
			if (existing.exists(resourceName))
			{
				if (stripPNG)
					rememberStrippedPNG(asset);
				else
					finalAssets.push(asset);
				continue;
			}

			var output = Path.combine(astcCache, resourceName);
			if (compressPNG(project, asset.sourcePath, output))
			{
				var astcAsset = asset.clone();
				astcAsset.sourcePath = output;
				astcAsset.resourceName = resourceName;
				astcAsset.targetPath = replaceExtension(asset.targetPath, "astc");
				astcAsset.id = astcAsset.targetPath;
				astcAsset.flatName = replaceExtension(asset.flatName, "astc");
				astcAsset.format = "astc";
				astcAsset.type = BINARY;
				astcAsset.embed = false;
				astcAsset.encrypt = false;
				finalAssets.push(astcAsset);
				existing.set(resourceName, true);
				if (stripPNG)
					rememberStrippedPNG(asset);
				else
					finalAssets.push(asset);
			}
			else
			{
				if (strict)
					Log.error("ASTC strict mode failed to convert PNG asset: " + asset.sourcePath + ". PNG fallback is disabled.");
				else
					finalAssets.push(asset);
			}
		}

		project.assets = finalAssets;
	}

	private static function shouldExcludeCompression(asset:Asset, extraPath:String = null):Bool
    {
    	if (compressionExcludes == null || compressionExcludes.length == 0)
    		return false;
    
    	var paths:Array<String> = [];
    
    	if (asset != null)
    	{
    		if (asset.resourceName != null)
    			paths.push(asset.resourceName);
    
    		if (asset.sourcePath != null)
    			paths.push(asset.sourcePath);
    
    		if (asset.targetPath != null)
    			paths.push(asset.targetPath);
    	}
    
    	if (extraPath != null)
    		paths.push(extraPath);
    
    	for (path in paths)
    	{
    		var normalized = normalize(path);
    
    		for (rule in compressionExcludes)
    		{
    			if (matchExcludeRule(normalized, rule))
    				return true;
    		}
    	}
    
    	return false;
    }
    
    private static function loadCompressionExcludes():Array<String>
    {
    	var result:Array<String> = [];
    	var file = "./compression-excludes.txt";
    
    	if (!FileSystem.exists(file))
    		return result;
    
    	try
    	{
    		var content = File.getContent(file);
    
    		for (line in content.split("\n"))
    		{
    			line = StringTools.trim(line);
    
    			if (line == "" || StringTools.startsWith(line, "#"))
    				continue;
    
    			result.push(normalize(line));
    		}
    	}
    	catch (e:Dynamic)
    	{
    		Log.warn("Failed to read compression-excludes.txt: " + e);
    	}
    
    	return result;
    }
    
    private static function matchExcludeRule(path:String, rule:String):Bool
    {
    	path = path.toLowerCase();
    	rule = rule.toLowerCase();
    
    	if (rule.indexOf("*") == -1)
    		return path == rule;
    
    	var parts = rule.split("*");
    	var index = 0;
    
    	for (part in parts)
    	{
    		if (part == "")
    			continue;
    
    		var found = path.indexOf(part, index);
    
    		if (found == -1)
    			return false;
    
    		index = found + part.length;
    	}
    
    	return true;
    }
	
	public static function getStrippedPNGAssets():Array<Asset>
	{
		return strippedPNGAssets;
	}

	private static function rememberStrippedPNG(asset:Asset):Void
	{
		strippedPNG++;
		if (asset != null)
			strippedPNGAssets.push(asset.clone());
	}

	public static function finish(project:HXProject):Void
	{
		if (!isEnabled(project))
			return;

		Log.info("", " - \x1b[1mASTC texture conversion summary:\x1b[0m " + converted + " converted, " + skipped + " cached, "
			+ failed + " failed, " + strippedPNG + " png stripped");
	}

	public static function compressCopiedAsset(project:HXProject, asset:Asset, destination:String):Void
    {
    	if (!isEnabled(project) || !isPNGAsset(asset, destination))
    		return;
    
    	ensureCompressionExcludes(project);
    
    	if (shouldExcludeCompression(asset, destination))
    	{
    		Log.info("", " - ASTC excluded: " + destination);
    		return;
    	}
    
    	var output = Path.withoutExtension(destination) + ".astc";
    	compressPNG(project, destination, output);
    }

	private static function compressPNG(project:HXProject, input:String, output:String):Bool
	{
		if (input == null || input == "" || !FileSystem.exists(input))
			return false;

		if (isFastCacheValid(project, input, output))
		{
			cleanupPreparedInput(output + ".premul.png", input);
			skipped++;
			return true;
		}

		var info = analyzeInput(input);
		var blockSize = getEffectiveBlockSize(project, input, info);
		var meta = getMeta(project, input, blockSize);
		var legacyMeta = getLegacyMeta(project, blockSize);
		var existingMeta = FileSystem.exists(getMetaPath(output)) ? File.getContent(getMetaPath(output)) : null;

		if (FileSystem.exists(output)
			&& !System.isNewer(input, output)
			&& (existingMeta == meta || existingMeta == legacyMeta))
		{
			cleanupPreparedInput(output + ".premul.png", input);
			File.saveContent(getMetaPath(output), meta);
			skipped++;
			return true;
		}

		System.mkdir(Path.directory(output));
		if (FileSystem.exists(output))
			FileSystem.deleteFile(output);
		if (FileSystem.exists(getMetaPath(output)))
			FileSystem.deleteFile(getMetaPath(output));

		var ok = false;
		var encoder = getDirectEncoder();
		var source = prepareInputPNG(project, input, output);
		if (encoder != null && encoder != "")
			ok = compressWithAstcenc(project, encoder, source, output, blockSize);
		else
			ok = compressWithAstcCompressor(project, source, output, blockSize);
		cleanupPreparedInput(source, input);

		if (ok && FileSystem.exists(output))
		{
			File.saveContent(getMetaPath(output), meta);
			converted++;
			Log.info("", " - \x1b[1mWriting ASTC texture:\x1b[0m " + output + " block=" + blockSize);
			return true;
		}
		else
		{
			failed++;
			Log.warn("ASTC conversion failed: " + input);
			return false;
		}
	}

	private static function isEnabled(project:HXProject):Bool
	{
		return project != null && project.config.getBool("android.astc-textures", true);
	}

	private static function ensureCompressionExcludes(project:HXProject):Void
    {
    	if (compressionExcludes == null)
    		compressionExcludes = loadCompressionExcludes();
    }
	
	private static function isPNGAsset(asset:Asset, destination:String):Bool
	{
		if (asset == null || destination == null)
			return false;

		var ext = Path.extension(destination);
		return ext != null && ext.toLowerCase() == "png";
	}

	private static function getBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-blocksize", "4x4"), "4x4");
	}

	private static function getDetailBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-detail-blocksize", "4x4"), "4x4");
	}

	private static function getLargeBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-large-blocksize", "8x8"), "8x8");
	}

	private static function getHugeBlockSize(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-huge-blocksize", "10x10"), "10x10");
	}

	private static function getQuality(project:HXProject):String
	{
		return sanitize(project.config.getString("android.astc-quality", "thorough"), "thorough");
	}

	private static function getColorProfile(project:HXProject):String
	{
		var profile = sanitize(project.config.getString("android.astc-colorprofile", "cl"), "cl");
		if (StringTools.startsWith(profile, "-"))
			profile = profile.substr(1);
		return profile;
	}

	private static function getPremultiplyAlpha(project:HXProject):Bool
	{
		return project.config.getBool("android.astc-premultiply-alpha", true);
	}

	private static function getStrict(project:HXProject):Bool
	{
		return project.config.getBool("android.astc-strict", project.config.getBool("android.astc-strip-png", true));
	}

	private static function getSmartBlocks(project:HXProject):Bool
	{
		return project.config.getBool("android.astc-smart-blocks", true);
	}

	private static function isFastCacheValid(project:HXProject, input:String, output:String):Bool
	{
		if (!FileSystem.exists(output) || !FileSystem.exists(getMetaPath(output)))
			return false;

		try
		{
			var cachedMeta = File.getContent(getMetaPath(output));
			if (StringTools.startsWith(cachedMeta, getCacheHeader(project, input)))
				return true;

			return tryUpgradeLegacyCache(project, input, output, cachedMeta);
		}
		catch (e:Dynamic) {}

		return false;
	}

	private static function tryUpgradeLegacyCache(project:HXProject, input:String, output:String, cachedMeta:String):Bool
	{
		if (cachedMeta == null || cachedMeta == "" || System.isNewer(input, output))
			return false;

		var blockSize = getMetaValue(cachedMeta, "block");
		if (blockSize == null || blockSize == "")
			return false;

		if (cachedMeta != getLegacyMeta(project, blockSize))
			return false;

		File.saveContent(getMetaPath(output), getMeta(project, input, blockSize));
		return true;
	}

	private static function getMetaValue(meta:String, key:String):String
	{
		if (meta == null)
			return null;

		var prefix = key + "=";
		for (line in meta.split("\n"))
		{
			if (StringTools.startsWith(line, prefix))
				return line.substr(prefix.length);
		}

		return null;
	}

	private static function getMeta(project:HXProject, input:String, blockSize:String):String
	{
		return getCacheHeader(project, input)
			+ "block=" + blockSize
			+ "\n";
	}

	private static function getCacheHeader(project:HXProject, input:String):String
	{
		return "version=2"
			+ "\nsource=" + getSourceSignature(input)
			+ "\nsettings=" + getSettingsSignature(project)
			+ "\n";
	}

	private static function getSourceSignature(input:String):String
	{
		try
		{
			var stat = FileSystem.stat(input);
			return normalize(input) + "|" + stat.size + "|" + Std.int(stat.mtime.getTime());
		}
		catch (e:Dynamic) {}

		return normalize(input) + "|missing|0";
	}

	private static function getSettingsSignature(project:HXProject):String
	{
		return [
			"block=" + getBlockSize(project),
			"quality=" + getQuality(project),
			"colorprofile=" + getColorProfile(project),
			"premultiplyAlpha=" + getPremultiplyAlpha(project),
			"smartBlocks=" + getSmartBlocks(project),
			"detailBlock=" + getDetailBlockSize(project),
			"largeBlock=" + getLargeBlockSize(project),
			"hugeBlock=" + getHugeBlockSize(project),
			"detailMaxSide=" + project.config.getInt("android.astc-detail-max-side", 1024),
			"detailMinSide=" + project.config.getInt("android.astc-detail-min-side", 256),
			"detailAlphaMaxPixels=" + project.config.getInt("android.astc-detail-alpha-max-pixels", 1048576),
			"largePixels=" + project.config.getInt("android.astc-large-pixels", 4194304),
			"hugePixels=" + project.config.getInt("android.astc-huge-pixels", 16777216),
			"largeMaxSide=" + project.config.getInt("android.astc-large-max-side", 2048),
			"hugeMaxSide=" + project.config.getInt("android.astc-huge-max-side", 4096),
			"detailAlphaRatio=" + project.config.getFloat("android.astc-detail-alpha-ratio", 0.08),
			"detailSemiAlphaRatio=" + project.config.getFloat("android.astc-detail-semi-alpha-ratio", 0.01)
		].join("|");
	}

	private static function getLegacyMeta(project:HXProject, blockSize:String):String
	{
		return "block=" + blockSize
			+ "\nquality=" + getQuality(project)
			+ "\ncolorprofile=" + getColorProfile(project)
			+ "\npremultiplyAlpha=" + getPremultiplyAlpha(project)
			+ "\nsmartBlocks=" + getSmartBlocks(project)
			+ "\nstrict=" + getStrict(project)
			+ "\n";
	}

	private static function getMetaPath(output:String):String
	{
		return output + ".meta";
	}

	private static function sanitize(value:String, fallback:String):String
	{
		if (value == null)
			return fallback;
		value = StringTools.trim(value);
		return value == "" ? fallback : value;
	}

	private static function prepareInputPNG(project:HXProject, input:String, output:String):String
	{
		if (!getPremultiplyAlpha(project))
			return input;

		var temp = output + ".premul.png";
		if (FileSystem.exists(temp) && !System.isNewer(input, temp))
			return temp;

		try
		{
			var image = Image.fromFile(input);
			if (image == null || image.buffer == null || image.buffer.data == null)
				return input;

			image.format = PixelFormat.RGBA32;
			if (image.premultiplied)
				image.premultiplied = false;

			var data = image.buffer.data;
			var pixels = image.width * image.height;
			for (i in 0...pixels)
			{
				var offset = i * 4;
				var alpha = data[offset + 3];
				if (alpha <= 0)
				{
					data[offset] = 0;
					data[offset + 1] = 0;
					data[offset + 2] = 0;
				}
				else if (alpha < 255)
				{
					data[offset] = Std.int((data[offset] * alpha + 127) / 255);
					data[offset + 1] = Std.int((data[offset + 1] * alpha + 127) / 255);
					data[offset + 2] = Std.int((data[offset + 2] * alpha + 127) / 255);
				}
			}

			image.buffer.premultiplied = false;
			var encoded = image.encode(ImageFileFormat.PNG);
			if (encoded == null || encoded.length == 0)
				return input;

			System.mkdir(Path.directory(temp));
			File.saveBytes(temp, encoded);
			return temp;
		}
		catch (e:Dynamic)
		{
			Log.warn("ASTC premultiply alpha preprocess failed: " + input + " (" + e + ")");
			return input;
		}
	}

	private static function cleanupPreparedInput(source:String, original:String):Void
	{
		if (source == null || source == "" || source == original)
			return;

		if (!StringTools.endsWith(source.toLowerCase(), ".premul.png"))
			return;

		try
		{
			if (FileSystem.exists(source))
				FileSystem.deleteFile(source);
		}
		catch (e:Dynamic) {}
	}

	private static function analyzeInput(input:String):ASTCImageInfo
	{
		var info = new ASTCImageInfo();
		try
		{
			var image = Image.fromFile(input);
			if (image == null || image.buffer == null || image.buffer.data == null)
				return info;

			image.format = PixelFormat.RGBA32;
			var data = image.buffer.data;
			var pixels = image.width * image.height;
			if (pixels <= 0)
				return info;

			info.width = image.width;
			info.height = image.height;
			info.pixels = pixels;

			var transparent = 0;
			var semiTransparent = 0;
			for (i in 0...pixels)
			{
				var alpha = data[(i * 4) + 3];
				if (alpha <= 8)
					transparent++;
				else if (alpha < 248)
					semiTransparent++;
			}

			info.transparentRatio = transparent / pixels;
			info.semiTransparentRatio = semiTransparent / pixels;
		}
		catch (e:Dynamic) {}
		return info;
	}

	private static function getEffectiveBlockSize(project:HXProject, input:String, info:ASTCImageInfo):String
	{
		var baseBlock = getBlockSize(project);
		if (!getSmartBlocks(project))
			return baseBlock;

		var detailBlock = getDetailBlockSize(project);
		if (baseBlock == detailBlock || info == null || info.width <= 0 || info.height <= 0)
			return baseBlock;

		var path = normalize(input).toLowerCase();
		var maxSide = Std.int(Math.max(info.width, info.height));
		var minSide = Std.int(Math.min(info.width, info.height));
		var detailMaxSide = project.config.getInt("android.astc-detail-max-side", 1024);
		var detailMinSide = project.config.getInt("android.astc-detail-min-side", 256);
		var detailAlphaMaxPixels = project.config.getInt("android.astc-detail-alpha-max-pixels", 1048576);
		var largePixels = project.config.getInt("android.astc-large-pixels", 4194304);
		var hugePixels = project.config.getInt("android.astc-huge-pixels", 16777216);
		var largeMaxSide = project.config.getInt("android.astc-large-max-side", 2048);
		var hugeMaxSide = project.config.getInt("android.astc-huge-max-side", 4096);
		var alphaRatio = project.config.getFloat("android.astc-detail-alpha-ratio", 0.08);
		var semiAlphaRatio = project.config.getFloat("android.astc-detail-semi-alpha-ratio", 0.01);

		var sensitivePath = path.indexOf("/ui/") != -1
			|| path.indexOf("/hud") != -1
			|| path.indexOf("/mobile") != -1
			|| path.indexOf("/notes") != -1
			|| path.indexOf("/note") != -1
			|| path.indexOf("/arrow") != -1
			|| path.indexOf("/strum") != -1
			|| path.indexOf("/splash") != -1
			|| path.indexOf("/menu") != -1
			|| path.indexOf("/menus") != -1
			|| path.indexOf("/icon") != -1
			|| path.indexOf("/icons") != -1
			|| path.indexOf("/title") != -1
			|| path.indexOf("/logo") != -1
			|| path.indexOf("/fonts") != -1;

		if (sensitivePath)
			return detailBlock;
		if (info.pixels >= hugePixels || maxSide >= hugeMaxSide)
			return getHugeBlockSize(project);
		if (info.pixels >= largePixels || maxSide >= largeMaxSide)
			return getLargeBlockSize(project);
		if (maxSide <= detailMaxSide)
			return detailBlock;
		if (minSide <= detailMinSide)
			return detailBlock;
		if (info.pixels <= detailAlphaMaxPixels && (info.transparentRatio >= alphaRatio || info.semiTransparentRatio >= semiAlphaRatio))
			return detailBlock;

		return baseBlock;
	}

	private static function compressWithAstcenc(project:HXProject, encoder:String, input:String, output:String, blockSize:String):Bool
	{
		var profile = "-" + getColorProfile(project);
		var quality = getQuality(project);
		if (!StringTools.startsWith(quality, "-"))
			quality = "-" + quality;

		ensureExecutable(encoder);
		var code = System.runCommand("", encoder, [profile, input, output, blockSize, quality], true, true);
		return code == 0;
	}

	private static function compressWithAstcCompressor(project:HXProject, input:String, output:String, blockSize:String):Bool
	{
		if (!hasAstcCompressor())
			return false;

		var outputRoot = getCompressorOutputRoot(input, output);
		var code = Haxelib.runCommand("", [
			"run",
			"astc-compressor",
			"compress",
			"-i",
			input,
			"-blocksize",
			blockSize,
			"-quality",
			getQuality(project),
			"-colorprofile",
			getColorProfile(project),
			"-o",
			outputRoot
		], true, true);

		if (code != 0)
			return false;

		var generated = findGeneratedAstc(outputRoot, input, output);
		if (!FileSystem.exists(output) && generated != null && FileSystem.exists(generated))
		{
			try
			{
				System.mkdir(Path.directory(output));
				if (FileSystem.exists(output))
					FileSystem.deleteFile(output);
				FileSystem.rename(generated, output);
			}
			catch (e:Dynamic) {}
		}

		return FileSystem.exists(output);
	}

	private static function getCompressorOutputRoot(input:String, output:String):String
	{
		var normalizedOutput = normalize(output);
		var normalizedInputAstc = normalize(replaceExtension(input, "astc"));

		if (StringTools.startsWith(normalizedInputAstc, "./"))
			normalizedInputAstc = normalizedInputAstc.substr(2);

		if (StringTools.endsWith(normalizedOutput, normalizedInputAstc))
		{
			var root = normalizedOutput.substr(0, normalizedOutput.length - normalizedInputAstc.length);
			if (StringTools.endsWith(root, "/"))
				root = root.substr(0, root.length - 1);
			if (root != "")
				return root;
		}

		return Path.directory(output);
	}

	private static function findGeneratedAstc(searchRoot:String, input:String, output:String):String
	{
		if (FileSystem.exists(output))
			return output;

		var normalizedInputAstc = normalize(replaceExtension(input, "astc"));
		if (StringTools.startsWith(normalizedInputAstc, "./"))
			normalizedInputAstc = normalizedInputAstc.substr(2);

		var exact = Path.combine(searchRoot, normalizedInputAstc);
		if (FileSystem.exists(exact))
			return exact;

		return findGeneratedAstcRecursive(searchRoot, normalizedInputAstc);
	}

	private static function findGeneratedAstcRecursive(directory:String, suffix:String):String
	{
		if (directory == null || directory == "" || !FileSystem.exists(directory) || !FileSystem.isDirectory(directory))
			return null;

		for (file in FileSystem.readDirectory(directory))
		{
			var path = Path.combine(directory, file);
			if (FileSystem.isDirectory(path))
			{
				var found = findGeneratedAstcRecursive(path, suffix);
				if (found != null)
					return found;
			}
			else
			{
				var normalized = normalize(path);
				if (StringTools.endsWith(normalized, suffix))
					return path;
			}
		}

		return null;
	}

	private static function replaceExtension(path:String, extension:String):String
	{
		if (path == null || path == "")
			return path;
		return Path.withoutExtension(path) + "." + extension;
	}

	private static function normalize(path:String):String
	{
		return StringTools.replace(Path.standardize(path), "\\", "/");
	}

	private static function hasAstcCompressor():Bool
	{
		if (compressorAvailable != null)
			return compressorAvailable;

		var output = Haxelib.runProcess("", ["path", "astc-compressor"], true, true, true);
		compressorAvailable = output != null && output.indexOf("Error:") == -1 && StringTools.trim(output) != "";
		return compressorAvailable;
	}

	private static function hasEncoder():Bool
	{
		var encoder = getDirectEncoder();
		return (encoder != null && encoder != "") || hasAstcCompressor();
	}

	private static function getDirectEncoder():String
	{
		if (checkedEncoder)
			return encoderPath;

		checkedEncoder = true;
		encoderPath = sanitize(Sys.getEnv("ASTC_ENCODER"), null);
		if (encoderPath != null && FileSystem.exists(encoderPath))
		{
			ensureExecutable(encoderPath);
			return encoderPath;
		}

		encoderPath = findBundledAstcCompressorEncoder();
		if (encoderPath != null && encoderPath != "")
			return encoderPath;

		var pathEnv = Sys.getEnv("PATH");
		if (pathEnv == null)
			return null;

		var separator = Sys.systemName() == "Windows" ? ";" : ":";
		var names = getEncoderNames();
		for (dir in pathEnv.split(separator))
		{
			dir = StringTools.trim(dir);
			if (dir == "")
				continue;

			for (name in names)
			{
				var candidate = Path.combine(dir, name);
				if (FileSystem.exists(candidate))
				{
					encoderPath = candidate;
					return encoderPath;
				}
			}
		}

		return null;
	}

	private static function findBundledAstcCompressorEncoder():String
	{
		var output = Haxelib.runProcess("", ["path", "astc-compressor"], true, true, true);
		if (output == null || output.indexOf("Error:") != -1)
			return null;

		var pluginDirs = switch (Sys.systemName())
		{
			case "Windows": ["plugins/Windows/x64", "plugins/Windows/x86", ""];
			case "Mac": ["plugins/macOS", ""];
			default: ["plugins/Linux/x64", "plugins/Linux", ""];
		}
		for (line in output.split("\n"))
		{
			var root = StringTools.trim(line);
			if (root == "" || StringTools.startsWith(root, "-") || StringTools.startsWith(root, "--"))
				continue;

			root = normalize(root);
			if (!FileSystem.exists(root))
				continue;

			for (pluginDir in pluginDirs)
			{
				var dir = pluginDir == "" ? root : Path.combine(root, pluginDir);
				// haxelib may strip executable permissions from bundled binaries,
				// so restore them for every encoder in the directory
				for (name in getEncoderNames())
				{
					var binary = Path.combine(dir, name);
					if (FileSystem.exists(binary))
						ensureExecutable(binary);
				}
				for (name in getEncoderNames())
				{
					var candidate = Path.combine(dir, name);
					if (FileSystem.exists(candidate))
						return candidate;
				}
			}
		}

		return null;
	}

	private static function getEncoderNames():Array<String>
	{
		if (Sys.systemName() == "Windows")
			return ["astcenc-avx2.exe", "astcenc-sse4.1.exe", "astcenc-sse2.exe", "astcenc.exe"];
		return ["astcenc-avx2", "astcenc-sse4.1", "astcenc-sse2", "astcenc"];
	}

	private static function ensureExecutable(path:String):Void
	{
		if (path == null || path == "" || Sys.systemName() == "Windows")
			return;

		try
		{
			Sys.command("chmod", ["+x", path]);
		}
		catch (e:Dynamic) {}
	}

	private static function warnMissingEncoder():Void
	{
		if (missingWarned)
			return;
		missingWarned = true;
		Log.warn("ASTC conversion skipped. Install `astc-compressor` or set ASTC_ENCODER to an astcenc executable.");
	}
}

private class ASTCImageInfo
{
	public var width:Int = 0;
	public var height:Int = 0;
	public var pixels:Int = 0;
	public var transparentRatio:Float = 0;
	public var semiTransparentRatio:Float = 0;

	public function new() {}
}
