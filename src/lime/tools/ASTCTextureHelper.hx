package lime.tools;

import hxp.Haxelib;
import hxp.Log;
import hxp.Path;
import hxp.System;
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

	public static function prepareProjectAssets(project:HXProject, targetDirectory:String):Void
	{
		converted = 0;
		skipped = 0;
		failed = 0;
		strippedPNG = 0;

		if (!isEnabled(project))
			return;

		Log.info("", " - \x1b[1mASTC texture conversion enabled:\x1b[0m block=" + getBlockSize(project)
			+ " quality=" + getQuality(project) + " colorprofile=" + getColorProfile(project));

		if (!hasEncoder())
		{
			warnMissingEncoder();
			return;
		}

		var astcCache = Path.combine(targetDirectory, "obj/astc-assets");
		var existing:Map<String, Bool> = [];
		for (asset in project.assets)
			existing.set(asset.resourceName, true);

		var stripPNG = project.config.getBool("android.astc-strip-png", true);
		var finalAssets:Array<Asset> = [];
		for (asset in project.assets)
		{
			if (!isPNGAsset(asset, asset.resourceName) || asset.embed == true || asset.sourcePath == null || asset.sourcePath == "")
			{
				finalAssets.push(asset);
				continue;
			}

			var resourceName = replaceExtension(asset.resourceName, "astc");
			if (existing.exists(resourceName))
			{
				if (stripPNG)
					strippedPNG++;
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
					strippedPNG++;
				else
					finalAssets.push(asset);
			}
			else
			{
				finalAssets.push(asset);
			}
		}

		project.assets = finalAssets;
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

		var output = Path.withoutExtension(destination) + ".astc";
		compressPNG(project, destination, output);
	}

	private static function compressPNG(project:HXProject, input:String, output:String):Bool
	{
		if (input == null || input == "" || !FileSystem.exists(input))
			return false;

		if (FileSystem.exists(output) && FileSystem.exists(getMetaPath(output)) && !System.isNewer(input, output) && File.getContent(getMetaPath(output)) == getMeta(project))
		{
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
		if (encoder != null && encoder != "")
			ok = compressWithAstcenc(project, encoder, input, output);
		else
			ok = compressWithAstcCompressor(project, input, output);

		if (ok && FileSystem.exists(output))
		{
			File.saveContent(getMetaPath(output), getMeta(project));
			converted++;
			Log.info("", " - \x1b[1mWriting ASTC texture:\x1b[0m " + output);
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

	private static function getMeta(project:HXProject):String
	{
		return "block=" + getBlockSize(project) + "\nquality=" + getQuality(project) + "\ncolorprofile=" + getColorProfile(project) + "\n";
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

	private static function compressWithAstcenc(project:HXProject, encoder:String, input:String, output:String):Bool
	{
		var profile = "-" + getColorProfile(project);
		var quality = getQuality(project);
		if (!StringTools.startsWith(quality, "-"))
			quality = "-" + quality;

		var code = System.runCommand("", encoder, [profile, input, output, getBlockSize(project), quality], true, true);
		return code == 0;
	}

	private static function compressWithAstcCompressor(project:HXProject, input:String, output:String):Bool
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
			getBlockSize(project),
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
			return encoderPath;

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

	private static function warnMissingEncoder():Void
	{
		if (missingWarned)
			return;
		missingWarned = true;
		Log.warn("ASTC conversion skipped. Install `astc-compressor` or set ASTC_ENCODER to an astcenc executable.");
	}
}
