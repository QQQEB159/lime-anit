package lime.utils;

import haxe.crypto.Sha256;

class AssetEncryption
{
	public static inline var MAGIC = "LMEENC1";

	private static inline var SALT = "lime-asset-encryption-v1";

	public static function decryptBytes(id:String, bytes:Bytes):Bytes
	{
		if (!isEncryptedBytes(bytes))
		{
			return bytes;
		}

		var decrypted = Bytes.alloc(bytes.length - MAGIC.length);
		transform(id, bytes, MAGIC.length, decrypted, 0, decrypted.length);
		return decrypted;
	}

	public static function encryptBytes(id:String, bytes:Bytes):Bytes
	{
		if (bytes == null)
		{
			return null;
		}

		var encrypted = Bytes.alloc(getEncryptedLength(bytes.length));
		var magicBytes = Bytes.ofString(MAGIC);
		encrypted.blit(0, magicBytes, 0, magicBytes.length);
		transform(id, bytes, 0, encrypted, magicBytes.length, bytes.length);
		return encrypted;
	}

	public static inline function getEncryptedLength(length:Int):Int
	{
		return length + MAGIC.length;
	}

	public static function isEncryptedBytes(bytes:Bytes):Bool
	{
		return bytes != null && bytes.length >= MAGIC.length && bytes.getString(0, MAGIC.length) == MAGIC;
	}

	private static function transform(id:String, source:Bytes, sourceOffset:Int, output:Bytes, outputOffset:Int, length:Int):Void
	{
		var seed = ((id != null) ? id : "") + ":" + SALT;
		var written = 0;
		var counter = 0;

		while (written < length)
		{
			var block = Bytes.fromBytes(Sha256.make(Bytes.ofString(seed + ":" + counter)));
			var blockLength = block.length;

			if (written + blockLength > length)
			{
				blockLength = length - written;
			}

			for (i in 0...blockLength)
			{
				output.set(outputOffset + written + i, source.get(sourceOffset + written + i) ^ block.get(i));
			}

			written += blockLength;
			counter++;
		}
	}
}
