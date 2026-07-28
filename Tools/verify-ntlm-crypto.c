#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <winpr/custom-crypto.h>

static int verify_md4(void)
{
	static const uint8_t expected[WINPR_MD4_DIGEST_LENGTH] = {
		0xdb, 0x34, 0x6d, 0x69, 0x1d, 0x7a, 0xcc, 0x4d,
		0xc2, 0x62, 0x5d, 0xb1, 0x9f, 0x9e, 0x3f, 0x52
	};
	static const uint8_t input[] = "test";
	uint8_t digest[WINPR_MD4_DIGEST_LENGTH] = { 0 };

	if (!winpr_Digest(WINPR_MD_MD4, input, sizeof(input) - 1, digest, sizeof(digest)))
	{
		fputs("WinPR MD4 initialization failed.\n", stderr);
		return 1;
	}
	if (memcmp(digest, expected, sizeof(expected)) != 0)
	{
		fputs("WinPR MD4 produced an unexpected digest.\n", stderr);
		return 1;
	}
	return 0;
}

static int verify_rc4(void)
{
	static const uint8_t key[] = "Key";
	static const uint8_t input[] = "Plaintext";
	static const uint8_t expected[] = {
		0xbb, 0xf3, 0x16, 0xe8, 0xd9, 0x40, 0xaf, 0x0a, 0xd3
	};
	uint8_t output[sizeof(expected)] = { 0 };
	WINPR_RC4_CTX* context = winpr_RC4_New(key, sizeof(key) - 1);

	if (!context)
	{
		fputs("WinPR RC4 initialization failed.\n", stderr);
		return 1;
	}
	if (!winpr_RC4_Update(context, sizeof(input) - 1, input, output))
	{
		fputs("WinPR RC4 update failed.\n", stderr);
		winpr_RC4_Free(context);
		return 1;
	}
	winpr_RC4_Free(context);
	if (memcmp(output, expected, sizeof(expected)) != 0)
	{
		fputs("WinPR RC4 produced an unexpected result.\n", stderr);
		return 1;
	}
	return 0;
}

int main(void)
{
	if (verify_md4() != 0)
		return 1;
	return verify_rc4();
}
