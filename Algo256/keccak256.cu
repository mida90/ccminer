/*
 * Keccak 256
 *
 */

extern "C"
{
#include "sph/sph_shavite.h"
#include "sph/sph_simd.h"
#include "sph/sph_keccak.h"

#include "miner.h"
}

#include "cuda_helper.h"

static uint32_t *d_hash[MAX_GPUS];
static uint32_t *h_nounce[MAX_GPUS];

extern void keccak256_cpu_init(int thr_id, uint32_t threads);
extern void keccak256_setBlock_80(void *pdata,const void *ptarget);
extern void keccak256_cpu_hash_80(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_hash, int order, uint32_t *h_nounce);

// CPU Hash
extern "C" void keccak256_hash(void *state, const void *input)
{
	sph_keccak_context ctx_keccak;

	uint32_t hash[16];

	sph_keccak256_init(&ctx_keccak);
	sph_keccak256 (&ctx_keccak, input, 80);
	sph_keccak256_close(&ctx_keccak, (void*) hash);

	memcpy(state, hash, 32);
}

static bool init[MAX_GPUS] = { 0 };

extern "C" int scanhash_keccak256(int thr_id, uint32_t *pdata,
	const uint32_t *ptarget, uint32_t max_nonce,
	unsigned long *hashes_done)
{
	const uint32_t first_nonce = pdata[19];
	uint32_t throughput = device_intensity(thr_id, __func__, 1U << 21); // 256*256*8*4
	throughput = min(throughput, (max_nonce - first_nonce));

	if (opt_benchmark)
		((uint32_t*)ptarget)[7] = 0x0005;

	if (!init[thr_id]) {
		CUDA_SAFE_CALL(cudaSetDevice(device_map[thr_id]));
		cudaDeviceReset();
		cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
		cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);

		CUDA_SAFE_CALL(cudaMalloc(&d_hash[thr_id], 16 * sizeof(uint32_t) * throughput));
		keccak256_cpu_init(thr_id, (int)throughput);
		CUDA_SAFE_CALL(cudaMallocHost(&h_nounce[thr_id], 4 * sizeof(uint32_t)));
		init[thr_id] = true;
	}

	uint32_t endiandata[20];
	for (int k=0; k < 20; k++) {
		be32enc(&endiandata[k], ((uint32_t*)pdata)[k]);
	}

	keccak256_setBlock_80((void*)endiandata, ptarget);

	do {
		int order = 0;

		keccak256_cpu_hash_80(thr_id, (int) throughput, pdata[19], d_hash[thr_id], order++, h_nounce[thr_id]);
		if (h_nounce[thr_id][0] != UINT32_MAX)
		{
			uint32_t Htarg = ptarget[7];
			uint32_t vhash64[8];
			be32enc(&endiandata[19], h_nounce[thr_id][0]);
			keccak256_hash(vhash64, endiandata);

			if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget))
			{
				int res = 1;
				// check if there was some other ones...
				*hashes_done = pdata[19] - first_nonce + throughput;
				if (h_nounce[thr_id][1] != 0xffffffff)
				{
					pdata[21] = h_nounce[thr_id][1];
					res++;
					if (opt_benchmark)
						applog(LOG_INFO, "GPU #%d Found second nounce %08x", thr_id, h_nounce[thr_id][1], vhash64[7], Htarg);
				}
				pdata[19] = h_nounce[thr_id][0];
				if (opt_benchmark)
					applog(LOG_INFO, "GPU #%d Found nounce %08x", thr_id, h_nounce[thr_id][0], vhash64[7], Htarg);
				return res;
			}
			else
			{
				if (vhash64[7] != Htarg)
				{
					applog(LOG_INFO, "GPU #%d: result for %08x does not validate on CPU!", thr_id, h_nounce[thr_id][0]);
				}
			}
		}

		pdata[19] += throughput;
	} while (!work_restart[thr_id].restart && ((uint64_t)max_nonce > ((uint64_t)(pdata[19]) + (uint64_t)throughput)));

	*hashes_done = pdata[19] - first_nonce;
	return 0;
}
