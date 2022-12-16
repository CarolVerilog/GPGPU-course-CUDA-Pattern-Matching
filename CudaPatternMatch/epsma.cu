#include "epsma.cuh"
#include "common.cuh"
#include <stdlib.h>
#include <memory.h>
#include <math.h>
#include <immintrin.h>

void epsmaBuildCpu(char** extendedPtr)
{
	// ��ģʽ��ÿ���ַ�����16������SIMD�Ƚ�
	// ���罫ģʽ��"ab"��չΪ
	// "aaaaaaaaaaaaaaaabbbbbbbbbbbbbbbb"

	*extendedPtr = (char*)malloc(patternLen * 16);
	char* extended = *extendedPtr;

	for (int i = 0; i < patternLen; ++i)
	{
		memset(extended + i * 16, pattern[i], 16);
	}
}

void epsmaCpu()
{
	char* extended;
	epsmaBuildCpu(&extended);
	
	int* matchNum;
	int* matchIdx;
	patternMatchCpuMalloc(&matchNum, &matchIdx);

	for (int i = 0; i < textLen; i += 16 - patternLen + 1)
	{
		auto simdText = _mm_loadu_si128((const __m128i*)(text + i));
		int matchRes = 0xffff;

		for (int j = 0; j < patternLen; ++j)
		{
			// ��ģʽ��ÿ���ַ�����16�β�����SIMD�Ĵ���
			// �뵱ǰɨ�赽��16������SIMD�Ĵ������ı��ַ����бȽ�
			// �ȽϽ����16bit�洢��������jλ����һ�ν����������
			// ѭ������֮�����ȽϽ����Ϊ0��˵��ƥ��ɹ�

			// ����ab��abcdacccddddabac�Ƚ�
			// ��һ�αȽϽ�a*16���ı��Ƚ�
			// ���Ϊ0101000000010001���ý��Ϊ���Ϊ��λ�ȽϽ�����ұ�Ϊ��λ�ȽϽ����
			// �ڶ��αȽϽ�b*16���ı��Ƚ�
			// ���Ϊ0010000000000010������һλ����һ�ν������ã�0001000000000001
			
			// ���Կ���ƥ���ԭ���ǵ�nΪ�ıȽϽ������nλ��������patternLen�αȽϺ�
			// ��λ����Ȼ��1����˵����λ������patternLen���ַ���ģʽ����ƥ��
			// ����ÿ�ֱȽ϶���Ҫ������ַ�������Ƚ�6��λ�õ�ƥ�䣬ģʽ������Ϊ2
			// ����Ҫ7���ַ��������6���ַ��޷�����ƥ��
			// ��Ϊ�˳������SIMD�Ĵ����Ŀռ䣬ģʽ���������Ϊ16

			auto simdPattern = _mm_loadu_si128((const __m128i*)(extended + j * 16));
			auto cmpRes = _mm_cmpeq_epi8(simdText, simdPattern);
			matchRes &= _mm_movemask_epi8(cmpRes) >> j;

			if (!matchRes)
			{
				break;
			}
		}

		if (matchRes)
		{
			for (int j = 0; j < 16 - patternLen + 1; ++j)
			{
				if (((matchRes >> j) & 0x1) && i + j < textLen - patternLen)
				{
					matchIdx[*matchNum] = i + j;
					++(*matchNum);
				}
			}
		}
	}

#ifdef PRINT
	printMatchOutputCpu(matchNum, matchIdx);
#endif

	free(extended);
	patternMatchCpuFree(matchNum, matchIdx);
}

void __global__ epsmaKernel(const char* __restrict__ text, const int textLen, const char* __restrict__ pattern, const int patternLen, int* matchNum, int* matchIdx)
{
	__shared__ int sharedMatchNum;
	__shared__ int sharedWriteIdx;
	extern __shared__ char sharedMemory[];
	int* sharedMatchIdx = (int*)sharedMemory;
	char* sharedPattern = (char*)(sharedMatchIdx + blockDim.x);
	char* sharedText = sharedPattern + patternLen;

	sharedMatchNum = 0;
	int blockTextIdx = blockIdx.x * blockDim.x;
	int blockTextLen = blockDim.x + patternLen - 1;
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);
	int perThreadTextLen = ceil(blockTextLen * 1.0 / blockDim.x);

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
	}

	for (int i = threadIdx.x * perThreadTextLen; i < (threadIdx.x + 1) * perThreadTextLen && i < blockTextLen && blockTextIdx + i < textLen; ++i)
	{
		sharedText[i] = text[blockTextIdx + i];
	}

	__syncthreads();

	int textIdx = blockTextIdx + threadIdx.x;
	if (textIdx <= textLen - patternLen)
	{
		int i = 0;
		for (; i < patternLen; ++i)
		{
			if (sharedPattern[i] != sharedText[threadIdx.x + i])
			{
				break;
			}
		}

		if (i == patternLen)
		{
			int idx = atomicAdd(&sharedMatchNum, 1);
			sharedMatchIdx[idx] = textIdx;
		}		
	}

	__syncthreads();

	if (threadIdx.x < sharedMatchNum)
	{
		if (threadIdx.x == 0)
		{
			sharedWriteIdx = atomicAdd(matchNum, sharedMatchNum);
		}

		__syncthreads();

		matchIdx[sharedWriteIdx + threadIdx.x] = sharedMatchIdx[threadIdx.x];
	}

}

void epsmaGpu()
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(textLen * 1.0 / blockSize.x);
	int blockTextLen = blockSize.x + patternLen - 1;

	int* matchNumDev = nullptr;
	int* matchIdxDev = nullptr;
	patternMatchGpuMalloc(&matchNumDev, &matchIdxDev);

	epsmaKernel <<< gridSize, blockSize, patternLen + blockTextLen + blockSize.x * sizeof(int) >>>  (textDev, textLen, patternDev, patternLen, matchNumDev, matchIdxDev);

#ifdef PRINT
	printMatchOutputGpu(matchNumDev, matchIdxDev);
#endif

	patternMatchGpuFree(matchNumDev, matchIdxDev);
}