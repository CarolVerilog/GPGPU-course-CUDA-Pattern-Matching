#include "kmp.cuh"
#include "common.cuh"
#include <stdlib.h>
#include <math.h>

void kmpNextCpu(int** nextPtr)
{
	// next�����¼�뵱ǰλ��֮ǰ���Ӵ��ĺ�׺��ͬ��ģʽ��ǰ׺����һ��λ��
	*nextPtr = (int*)malloc(patternLen * sizeof(int));
	int* next = *nextPtr;
	int i = 0;
	int j = -1;
	next[0] = -1;

	while (i < patternLen - 1)
	{
		if (j == -1 || pattern[i] == pattern[j])
		{
			++i, ++j;
			if (pattern[i] != pattern[j])
			{
				// ����ģʽ�����Ӵ�[i-j,i-1]��ǰ׺[0,j-1]��ͬ
				// ��j��Ϊ��ģʽ����iλ��֮ǰ���Ӵ��ĺ�׺��ȵ�ģʽ��ǰ׺�ĺ�һ���ַ�
				next[i] = j;
			}
			else
			{
				// ���ַ����
				// ���ʱ�Ӵ�[i-j,i-1]���Ӵ�[0,j-1]���
				// ��j����next[i]�Ƿ���Ҫ���
				// ����ת֮������i��jλ���ַ���������ı��ַ���Ȼ��ƥ��
				// �ʽ�next[j]����next[i]�������Ż�
				next[i] = next[j];
			}
		}
		else
		{
			// ģʽ�����ȣ���j������next[j]��������
			j = next[j];
		}
	}
}

void kmpCpu()
{
	int* next = nullptr;
	int i = 0;
	int j = 0;
	kmpNextCpu(&next);

	int* matchNum;
	int* matchIdx;
	patternMatchCpuMalloc(&matchNum, &matchIdx);

	while (i < textLen)
	{
		if (j == -1 || text[i] == pattern[j])
		{
			++i, ++j;
		}
		else
		{
			j = next[j];
		}

		if (j == patternLen)
		{
			i -= patternLen;
			j = -1;
			matchIdx[*matchNum] = i;
			++(*matchNum);
		}
	}

#ifdef PRINT
	printMatchOutputCpu(matchNum, matchIdx);
#endif
	
	free(next);
	patternMatchCpuFree(matchNum, matchIdx);
}

void __global__ kmpKernel(const char* __restrict__ text, const int textLen, const int threadTextLen, const char* __restrict__ pattern, const int patternLen, const int* __restrict__ next, int* matchNum, int* matchIdx)
{
	// ����ÿ���̶߳�������һ���ı��������ڴ��޷�����ÿ��block���账���ı����ʲ����ı����ؽ������ڴ�
	// ����block�����ı���������ƥ����Ҳ�ϴ󣬹��޷�����˽�л�ԭ�Ӳ���
	extern __shared__ char sharedMemory[];
	int* sharedNext = (int*)sharedMemory;
	char* sharedPattern = (char*)(sharedNext + patternLen);
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
		sharedNext[i] = next[i];
	}

	__syncthreads();

	// Ϊȷ���ҵ�����ƥ�䣬ÿ���̶߳�����ģʽ������-1���ַ�
	int extendedThreadTextLen = threadTextLen + patternLen - 1;
	int textIdx = (blockIdx.x * blockDim.x + threadIdx.x) * threadTextLen;

	int i = 0;
	int j = 0;
	
	while (i < extendedThreadTextLen && textIdx + i < textLen)
	{
		if (j == -1 || text[textIdx + i] == sharedPattern[j])
		{
			++i, ++j;
		}
		else
		{
			j = sharedNext[j];
		}

		if (j == patternLen)
		{
			i -= patternLen;
			j = -1;

			int idx = atomicAdd(matchNum, 1);
			matchIdx[idx] = textIdx + i;
		}
	}
}

void kmpGpu()
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(textLen * 1.0 / (blockSize.x * threadTextLen));

	int* next = nullptr;
	int* nextDev = nullptr;

	// ����next��������ɵ�Ԫ�������������ɵ�Ԫ�أ��ʲ�ʹ�ò��л�����
	kmpNextCpu(&next);
	cudaMalloc(&nextDev, sizeof(int) * patternLen);
	cudaMemcpy(nextDev, next, sizeof(int) * patternLen, cudaMemcpyHostToDevice);
	free(next);

	int* matchNumDev = nullptr;
	int* matchIdxDev = nullptr;
	patternMatchGpuMalloc(&matchNumDev, &matchIdxDev);

	kmpKernel <<< gridSize, blockSize, patternLen * (sizeof(char) + sizeof(int)) >>> (textDev, textLen, threadTextLen, patternDev, patternLen, nextDev, matchNumDev, matchIdxDev);

#ifdef PRINT
	printMatchOutputGpu(matchNumDev, matchIdxDev);
#endif

	cudaFree(nextDev);
	patternMatchGpuFree(matchNumDev, matchIdxDev);
}
