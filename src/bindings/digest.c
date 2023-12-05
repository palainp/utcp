#include <stdint.h>
#include <stdlib.h>

CAMLprim value
digest_32_le (value data, value len)
{
    CAMLparam2(data, len);
    CAMLlocal3(v_result);

	uint64_t sum = 0;
	uint64_t sum1 = 0;
	const uint64_t *u64 = (const uint64_t *)data;

	while (len >= 8) {
		uint64_t d = *u64;
		sum  += d&0xffffffff;
		sum1 += d>>32;
		u64 += 1;
		len -= 8;
	}
	sum += sum1;

	// Collect remaining 16b data
	const uint16_t *u16 = (const uint16_t *)u64;
	while (len >= 2) {
		sum += *u16;
		u16 += 1;
		len -= 2;
	}

	// Last one byte?
	if (len == 1)
		sum += *((const uint8_t *)u16);

	// Fold sum into 16-bit word.
	while (sum>>16) {
		sum = (sum & 0xffff) + (sum>>16);
	}
    CAMLreturn((uint16_t)~sum);
}
