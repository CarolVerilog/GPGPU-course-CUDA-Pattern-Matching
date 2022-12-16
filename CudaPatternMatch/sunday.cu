#include "sunday.cuh"
#include "common.cuh"
#include <stdlib.h>
#include <memory.h>
#include <math.h>

void sundayMoveCpu(int** movePtr)
{
	*movePtr = (int*)malloc(ALPHABET_SIZE * sizeof(int));
	int* move = *movePtr;
	memset(move, 0xff, sizeof(int) * ALPHABET_SIZE);

	// ��ǰ����˳�����������Ӧ�ַ�λ�õ�moveֵ�޸�Ϊ��ǰiֵ
	// ͨ�����ַ�����֤move�д洢����ĳ���ַ������ֵ�λ��
	// ƥ���������תʱ���Ա���Ӧ��ת���ȹ������¶�ʧƥ��
	for (int i = 0; i < patternLen; ++i)
	{
		move[pattern[i]] = i;
	}
}

void sundayCpu()
{
	int* move;
	sundayMoveCpu(&move);

	int* matchNum;
	int* matchIdx;
	patternMatchCpuMalloc(&matchNum,&matchIdx);

	int i = 0;

	while (i <= textLen - patternLen)
	{
		int j = 0;
		int k = i;

		while (j < patternLen && text[k] == pattern[j])
		{
			++k;
			++j;
		}

		if (j == patternLen)
		{
			matchIdx[*matchNum] = i;
			++(*matchNum);

			i += 1;
		}
		else
		{
			// ��ƥ��ʧ�ܣ���˵���Ӵ�[i,i+patternLen-1]��ģʽ��ƥ��ʧ��
			// ��ʱ��鵱ǰ�ı�λ�ü���ģʽ������֮����ַ�����i+patternLenλ�õ��ַ�
			// ��Ϊ����Ŀ��ܳɹ���ƥ����[i+1,i+patternLen]
			// ���i+patternLenλ�õ��ַ���ģʽ�������һ�γ��ֵ�λ�ò�ִ����ת
			// �������������ת��������ֱ�ӽ�i��ת��i+patternLen+1��Ч�ʺܸ�

			int lastPos = move[text[i + patternLen]];
			int offset = patternLen - lastPos;
			i += offset;
		}
	}

#ifdef PRINT
	printMatchOutputCpu(matchNum, matchIdx);
#endif

	free(move);
	patternMatchCpuFree(matchNum, matchIdx);
}

void __global__ sundayMoveKernel(const char* __restrict__ pattern, const int patternLen, int* move)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;

	if (idx < patternLen)
	{
		// ���м����ַ����ֵ����λ��ʱ��ֹд���ͻ
		// ���ﲻ��Ҫʹ��˽��ԭ�Ӳ�������Ϊֻ����һ��д��
		atomicMax(move + pattern[idx], idx);
	}
}

void __global__ sundayKernel(const char* __restrict__ text, const int textLen, const int threadTextLen, const char* __restrict__ pattern, const int patternLen, const int* __restrict__ move, int* matchNum, int* matchIdx)
{
	// ����ÿ���̶߳�������һ���ı��������ڴ��޷�����ÿ��block���账���ı����ʲ����ı����ؽ������ڴ�
	// ����block�����ı���������ƥ����Ҳ�ϴ󣬹��޷�����˽�л�ԭ�Ӳ���
	__shared__ int sharedMove[ALPHABET_SIZE];
	extern __shared__ char sharedPattern[];
	int perThreadMoveLen = ceil(ALPHABET_SIZE * 1.0 / blockDim.x);
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);
	
	for (int i = threadIdx.x * perThreadMoveLen; i < (threadIdx.x + 1) * perThreadMoveLen && i < ALPHABET_SIZE; ++i)
	{
		sharedMove[i] = move[i];
	}

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
	}

	__syncthreads();

	// Ϊȷ���ҵ�����ƥ�䣬ÿ���̶߳�����ģʽ������-1���ַ�
	int extendedThreadTextLen = threadTextLen + patternLen - 1;
	int textIdx = (blockIdx.x * blockDim.x + threadIdx.x) * threadTextLen;
	int i = 0;

	while (i < threadTextLen && textIdx + i < textLen)
	{
		int j = 0;
		int k = i;

		while (j < patternLen && text[textIdx + k] == sharedPattern[j])
		{
			++k;
			++j;
		}

		if (j == patternLen)
		{
			int idx = atomicAdd(matchNum, 1);
			matchIdx[idx] = textIdx + i;

			i += 1;
		}
		else
		{
			int lastPos = sharedMove[text[textIdx + i + patternLen]];
			int offset = patternLen - lastPos;
			i += offset;
		}
	}
}



void sundayMoveGpu(int** movePtr)
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(patternLen * 1.0 / blockSize.x);

	cudaMalloc(movePtr, sizeof(int) * ALPHABET_SIZE);
	cudaMemset(*movePtr, 0xff, sizeof(int) * ALPHABET_SIZE);
	sundayMoveKernel <<< gridSize, blockSize, patternLen >>> (patternDev, patternLen, *movePtr);
}

void sundayGpu()
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(textLen * 1.0 / (blockSize.x * threadTextLen));

	int* matchNumDev = nullptr;
	int* matchIdxDev = nullptr;
	patternMatchGpuMalloc(&matchNumDev, &matchIdxDev);

	int* moveDev = nullptr;
	sundayMoveGpu(&moveDev);

	sundayKernel <<< gridSize, blockSize, patternLen >>> (textDev, textLen, threadTextLen, patternDev, patternLen, moveDev, matchNumDev, matchIdxDev);

#ifdef PRINT
	printMatchOutputGpu(matchNumDev, matchIdxDev);
#endif

	cudaFree(moveDev);
	patternMatchGpuFree(matchNumDev, matchIdxDev);
}
