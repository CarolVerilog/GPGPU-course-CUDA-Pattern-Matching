#include "ssef.cuh"
#include "common.cuh"
#include <stdlib.h>
#include <memory.h>
#include <math.h>
#include <immintrin.h>
#include <time.h>
#include <stdio.h>

#define ASCII_LEN 8
#define MAX_FILTER 65536

typedef struct SsefNode
{
	SsefNode* next = NULL;
	int idx = 1;
} SsefNode;

SsefNode filter[MAX_FILTER];
int filterLen;
int optimalOffset;
int validPatternLen;

void ssefGetOptimalOffsetCpu()
{
	// ͳ����ӽ�0��1��ռ50%��bitλ
	// ʹ�ô�λ���ɹ�ϣ����

	int bit[ASCII_LEN] = { 0 };

	for (int i = 0; i < patternLen; ++i)
	{
		for (int j = 0; j < ASCII_LEN; ++j)
		{
			bit[j] += (pattern[i] >> j) & 0x1;
		}
	}
	
	int minDist = INT_MAX;
	int optimalBit = 0;

	for (int i = 0; i < ASCII_LEN; ++i)
	{
		bit[i] = fabs(bit[i] - patternLen / 2);
		if (bit[i] < minDist)
		{
			minDist = bit[i];
			optimalBit = i;
		}
	}

	optimalOffset = ASCII_LEN - 1 - optimalBit;
}

void ssefBuildCpu()
{
	// ����һ��SIMD�Ĵ���������16���ַ�
	// �ʹ�ϣ���볤��Ϊ16
	ssefGetOptimalOffsetCpu();
	filterLen = 16;
	validPatternLen = patternLen - 15;

	for (int i = 0; i < validPatternLen; ++i)
	{
		// ��ÿ���ַ�����ѱ���λ���Ƶ�����λ��
		// ��16���ַ��ķ���λ��ɹ�ϣ����
		auto simdPattern = _mm_loadu_si128((const __m128i*)&pattern[i]);
		auto tmp128 = _mm_slli_epi64(simdPattern, optimalOffset);
		auto f = _mm_movemask_epi8(tmp128);

		// ����λ�ü�¼����ʽ��ϣ���Ӧ��λ����
		SsefNode* node = &filter[f];
		while (node->next != NULL)
		{
			node = node->next;
		}

		node->next = (SsefNode*)malloc(sizeof(SsefNode));
		node->next->next = NULL;
		node->next->idx = i;
	}
}

void ssefFree()
{
	for (int i = 0; i < MAX_FILTER; ++i)
	{
		while (filter[i].next != NULL)
		{
			SsefNode* node = filter[i].next;
			filter[i].next = filter[i].next->next;
			free(node);
		}
	}
}

void ssefCpu()
{	
	// SSEF�㷨˼·���£�
	// ����SIMD�Ĵ����������16���ַ����ʽ��ı�����16���ַ��ֿ飬��0��ʼ���
	// ����ģʽ������Ϊm����m>=32,ģʽ��һ������ռ��ĳһ�飬���ռ��n=floor(m/16)��
	// ����֤��ģʽ����ռ���Ŀ���һ���б��Ϊn-1�ı����Ŀ�
	// ����ÿ�ζ������Ϊn-1�ı����Ŀ飬������ѱ���λ�����ϣֵ��ѯ�Ѿ�����õĹ�ϣ��
	// ����ϣ���д洢��Ԫ�أ������ģʽ���е�ĳ��λ�õĹ�ϣֵ���ֵ��ͬ
	// �������ٽ������ַ��Ƚϼ���

	ssefBuildCpu();
	int searchWindowLen = (floor(patternLen * 1.0 / filterLen) - 1) * filterLen;
	
	int* matchNum;
	int* matchIdx;
	patternMatchCpuMalloc(&matchNum, &matchIdx);
	
	for (int i = searchWindowLen; i < textLen; i += searchWindowLen)
	{
		__m128i simdText = _mm_loadu_si128((const __m128i*) & text[i]);
		__m128i tmp128 = _mm_slli_epi64(simdText, optimalOffset);
		int f = _mm_movemask_epi8(tmp128);

		SsefNode* node = filter[f].next;
		while (node != NULL)
		{
			if (node->idx == 0 || node->idx > searchWindowLen)
			{
				node = node->next;
				continue;
			}

			int j = i - node->idx;
			int k = 0;

			for (; k < patternLen; ++j, ++k)
			{
				if (text[j] != pattern[k])
				{
					break;
				}
			}

			if (k == patternLen)
			{
				matchIdx[*matchNum] = i - node->idx;
				++(*matchNum);
			}

			node = node->next;
		}
	}
	
#ifdef PRINT
	printMatchOutputCpu(matchNum, matchIdx);
#endif

	ssefFree();
	patternMatchCpuFree(matchNum, matchIdx);
}

void __global__ ssefGetOptimalOffsetKernel(const char* __restrict__ pattern, const int patternLen, int* bit)
{
	// 
	__shared__ int sharedBit[ASCII_LEN];
	extern __shared__ char sharedPattern[];
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);

	if (threadIdx.x < ASCII_LEN)
	{
		sharedBit[threadIdx.x] = 0;
	}

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
	}

	__syncthreads();

	int patternIdx = blockIdx.x * blockDim.x + threadIdx.x;

	if (patternIdx < patternLen)
	{
		for (int i = 0; i < ASCII_LEN; ++i)
		{
			atomicAdd(sharedBit + i, (sharedPattern[threadIdx.x] >> i) & 0x1);
		}

		if (threadIdx.x < ASCII_LEN)
		{
			atomicAdd(bit + threadIdx.x, sharedBit[threadIdx.x]);
		}
	}
}

void __device__ ssefAtomicLinkKernel(const int idx, SsefNode* filter, const int f)
{
	for (int i = 0; i < 32; ++i)
	{
		if (threadIdx.x % 32 != i)
		{
			continue;
		}

		while (atomicExch(&filter[f].idx, 0) == 0);

		SsefNode* node = &filter[f];
		while (node->next != NULL)
		{
			node = node->next;
		}

		node->next = (SsefNode*)malloc(sizeof(SsefNode));
		node->next->next = NULL;
		node->next->idx = idx;

		filter[f].idx = 1;
		return;
	}
}

void __global__ ssefBuildKernel(const char* __restrict__ pattern, const int patternLen, const int filterLen, const int optimalOffset, SsefNode* filter)
{
	extern __shared__ char sharedMovedPattern[];
	int offset = ASCII_LEN - 1 - optimalOffset;
	int validPatternLen = patternLen - filterLen + 1;

	int blockPatternIdx = blockIdx.x * blockDim.x;
	int blockPatternLen = blockDim.x + filterLen - 1;
	int perThreadPatternLen = ceil(blockPatternLen * 1.0 / blockDim.x);

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < blockPatternLen && blockPatternIdx + i < patternLen; ++i)
	{
		sharedMovedPattern[i] = (pattern[blockPatternIdx + i] >> offset) & 0x1;
	}

	__syncthreads();

	int patternIdx = blockPatternIdx + threadIdx.x;
	if (patternIdx < validPatternLen)
	{
		int f = 0;
		for (int i = 0; i < filterLen; ++i)
		{
			f |= (sharedMovedPattern[threadIdx.x + i] << i);
		}

		ssefAtomicLinkKernel(patternIdx, filter, f);
	}
}

void __global__ ssefKernel(const char* __restrict__ text, const int textLen, const char* __restrict__ pattern, const int patternLen, const SsefNode* __restrict__ filter, const int filterLen, const int optimalOffset, int* matchNum, int* matchIdx)
{
	// ÿ���̸߳���ĳ���ַ�����λ���㲢д�빲���ڴ���
	extern __shared__ char sharedMemory[];
	char* sharedPattern = sharedMemory;
	char* sharedMovedText = sharedMemory + patternLen;
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);

	int offset = ASCII_LEN - 1 - optimalOffset;
	int validPatternLen = patternLen - filterLen + 1;
	int searchWindowLen = (floor(patternLen * 1.0 / filterLen) - 1) * filterLen;

	// ���ǽ��̰߳���СΪ16���飬ÿ���߳���λ���������
	// �ɸ����0���߳����ɹ�ϣֵ����ѯ��ϣ��
	// Ϊ�����Ч�ʲ��ý��������˼��
	// �������ͬ���߳̾���������ͬһwarp��ִ��
	// ����ÿ��warp32���߳�����ֻ��2���߳���ִ��
	int windowsCnt = blockDim.x / filterLen;
	int windowIdx = threadIdx.x % windowsCnt;
	int windowThreadIdx = threadIdx.x / windowsCnt;

	int textIdx = (blockIdx.x*windowsCnt + windowIdx + 1) * searchWindowLen + windowThreadIdx;
	int blockTextIdx = windowIdx * filterLen + windowThreadIdx;
	
	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
	}

	if (threadIdx.x < windowsCnt * filterLen)
	{
		sharedMovedText[blockTextIdx] = (text[textIdx] >> offset) & 0x1;
	}

	__syncthreads();
	
	if (windowThreadIdx == 0 && textIdx < textLen)
	{
		int f = 0;
		for (int i = 0; i < filterLen; ++i)
		{
			f |= sharedMovedText[blockTextIdx + i] << i;
		}
		
		SsefNode* node = filter[f].next;
		while (node != NULL)
		{
			if (node->idx == 0 || node->idx > searchWindowLen)
			{
				node = node->next;
				continue;
			}

			int j = textIdx - node->idx;
			int k = 0;

			for (; k < patternLen; ++j, ++k)
			{
				if (text[j] != pattern[k])
				{
					break;
				}
			}

			if (k == patternLen)
			{
				int idx = atomicAdd(matchNum, 1);
				matchIdx[idx] = textIdx - node->idx;
			}

			node = node->next;
		}
	}
}

void __global__ ssefFreeKernel(SsefNode* filter)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	while (idx < MAX_FILTER && filter[idx].next != NULL)
	{
		SsefNode* node = filter[idx].next;
		filter[idx].next = filter[idx].next->next;
		free(node);
	}
}

void ssefGetOptimalOffsetGpu()
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(patternLen * 1.0 / blockSize.x);

	int* bit = (int*)malloc(ASCII_LEN * sizeof(int));
	int* bitDev = nullptr;

	cudaMalloc(&bitDev, ASCII_LEN * sizeof(int));
	cudaMemset(bitDev, 0, ASCII_LEN * sizeof(int));
	ssefGetOptimalOffsetKernel <<< gridSize, blockSize, patternLen >>> (patternDev, patternLen, bitDev);
	cudaMemcpy(bit, bitDev, ASCII_LEN * sizeof(int), cudaMemcpyDeviceToHost);

	int minDist = INT_MAX;
	int optimalBit = 0;

	for (int i = 0; i < ASCII_LEN; ++i)
	{
		bit[i] = fabs(bit[i] - patternLen / 2);
		if (bit[i] < minDist)
		{
			minDist = bit[i];
			optimalBit = i;
		}
	}

	optimalOffset = ASCII_LEN - 1 - optimalBit;
}

void ssefBuildGpu(SsefNode** filterDevPtr)
{
	ssefGetOptimalOffsetGpu();

	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(patternLen * 1.0 / blockSize.x);

	filterLen = patternLen > 32 ? 16 : patternLen / 2;
	cudaMalloc(filterDevPtr, MAX_FILTER * sizeof(SsefNode));
	SsefNode* filterDev = *filterDevPtr;

	cudaMemcpy(filterDev, filter, MAX_FILTER * sizeof(SsefNode), cudaMemcpyHostToDevice);
	ssefBuildKernel <<< gridSize, blockSize, blockSize.x + filterLen - 1 >>> (patternDev, patternLen, filterLen, optimalOffset, filterDev);
}

void ssefGpu()
{
	SsefNode* filterDev;
	ssefBuildGpu(&filterDev);

	int searchWindowLen = (floor(patternLen * 1.0 / filterLen) - 1) * filterLen;
	int windowsCnt = textLen / searchWindowLen;
	int blockWindowsCnt = blockLen / filterLen;

	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(windowsCnt * 1.0 / blockWindowsCnt);

	int* matchNumDev;
	int* matchIdxDev;
	patternMatchGpuMalloc(&matchNumDev, &matchIdxDev);

	ssefKernel <<< gridSize, blockSize, patternLen + blockWindowsCnt * filterLen >>> (textDev, textLen, patternDev, patternLen, filterDev, filterLen, optimalOffset, matchNumDev, matchIdxDev);

#ifdef PRINT
	printMatchOutputGpu(matchNumDev, matchIdxDev);
#endif
	
	gridSize = ceil(MAX_FILTER * 1.0 / blockLen);
	ssefFreeKernel <<< gridSize, blockSize >>> (filterDev);
	cudaFree(filterDev);
	patternMatchGpuFree(matchNumDev, matchIdxDev);
}