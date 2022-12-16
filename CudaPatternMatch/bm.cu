#include "bm.cuh"
#include "common.cuh"
#include <math.h>
#include <stdlib.h>
#include <memory.h>

void bmBuildCpu(int** badCharPtr, int** goodSuffixPtr)
{
	*badCharPtr = (int*)malloc(ALPHABET_SIZE * sizeof(int));
	*goodSuffixPtr = (int*)malloc(patternLen * sizeof(int));
	int* maxSuffix = (int*)malloc(patternLen * sizeof(int));

	int* badChar = *badCharPtr;
	int* goodSuffix = *goodSuffixPtr;
	memset(badChar, 0xff, sizeof(int) * ALPHABET_SIZE);
	memset(goodSuffix, 0xff, sizeof(int) * patternLen);

	// ��ǰ����˳�����������Ӧ�ַ�λ�õ�badCharֵ�޸�Ϊ��ǰiֵ
	// ͨ�����ַ�����֤badChar�д洢����ĳ���ַ������ֵ�λ��
	// ƥ���������תʱ���Ա���Ӧ��ת���ȹ������¶�ʧƥ��
	for (int i = 0; i < patternLen; ++i)
	{
		badChar[pattern[i]] = i;
	}

	// ��maxSuffix�е�ÿ��λ��i��¼��ֵ�������Ӵ�[0-i]�ĺ�׺ƥ���
	// �ģʽ����׺�ĳ���
	maxSuffix[patternLen - 1] = patternLen;
	for (int i = 0; i < patternLen - 1; ++i)
	{
		int j = i;
		int k = patternLen - 1;
		int cnt = 0;

		while (j >= 0 && pattern[j]==pattern[k])
		{
			++cnt;
			--j;
			--k;
		}

		maxSuffix[i] = cnt;
	}

	// ͨ��maxSuffix�м�¼��ֵ���Ժ����׵ļ����
	// ģʽ����ÿ����׺��һ����ģʽ���г��ֵ�λ��
	// ��û�г�����Ϊ��ʼ��ֵ-1
	// ��¼���һ�γ���λ�õ�ԭ���뻵�ַ����鹹��������ͬ
	for (int i = 0; i < patternLen - 1; ++i)
	{
		if (maxSuffix[i] > 0)
		{
			goodSuffix[patternLen - maxSuffix[i]] = i;
		}
	}

	free(maxSuffix);
}

void bmCpu()
{
	int* badChar;
	int* goodSuffix;
	bmBuildCpu(&badChar, &goodSuffix);

	int* matchNum;
	int* matchIdx;
	patternMatchCpuMalloc(&matchNum, &matchIdx);

	int i = patternLen - 1;

	while (i < textLen)
	{
		int j = patternLen - 1;
		int k = i;
		int len = 0;

		// ƥ��ʱ�Ӻ���ǰƥ��
		while (j>=0 && text[k] == pattern[j])
		{
			--k;
			--j;
		}

		if (j < 0)
		{
			++k;
			matchIdx[*matchNum] = k;
			++(*matchNum);
			++i;
		}
		else
		{
			// ��ƥ��ʧ�ܣ���ʹ�û��ַ���ת������ú�׺��ת����
			// ѡȡ��ת���Ƚϴ���ִ����ת
			// ��������ת���Ⱦ�С��1����ת������Ϊ1

			// ���ַ����Խ���ǰλ���뵱ǰ�ı�λ�õ��ַ���ģʽ�������һ�γ��ֵ�λ��
			// �����Ϊ��ת���ȣ�������ת֮���ģʽ���ַ��뵱ǰ�ı�λ�õ��ַ����
			// �ٴ��ɺ���ǰƥ�伴��
			// �����������תλ�ÿ���Ϊ����������������ת��С����Ϊ1
			int largestGoodSuffixPos = -1;
			int offset = __max(1, j - badChar[text[k]]);

			// �ú�׺���Դ����Ѿ�ƥ��ɹ����ַ����������ɺ���ǰƥ��
			// ��ƥ��ɹ����ַ�����ģʽ���ĺ�׺
			// ����׺��֮ǰ��ģʽ����δ���֣������̺�׺����ֱ������Ϊֹ
			// ��ģʽ��β��λ�ü�ȥ��׺��һ�γ���λ����Ϊ��ת����
			// �������Ա�֤֮ǰ�Ѿ�ƥ��ĺ�׺û�б��˷�
			// ��û��һ����׺���ֹ����൱��û�ж���תλ�ý��д���
			for (int l = j + 1; l < patternLen - 1; ++l)
			{
				if (goodSuffix[l] != -1)
				{
					offset = __max(offset, patternLen - 1 - goodSuffix[l]);
					break;
				}
			}

			i += offset;
		}
	}

#ifdef PRINT
	printMatchOutputCpu(matchNum, matchIdx);
#endif

	free(badChar);
	free(goodSuffix);
	patternMatchCpuFree(matchNum, matchIdx);
}

void __global__ bmBadCharKernel(const char* __restrict__ pattern, const int patternLen, int* badChar)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;

	if (idx < patternLen)
	{
		// ���м����ַ����ֵ����λ��ʱ��ֹд���ͻ
		// ���ﲻ��Ҫʹ��˽��ԭ�Ӳ�������Ϊֻ����һ��д��
		atomicMax(badChar + pattern[idx], idx);
	}
}

void __global__ bmGoodSuffixKernel(const char* __restrict__ pattern, const int patternLen, int* goodSuffix)
{
	extern __shared__ char sharedPattern[];
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
	}

	__syncthreads();

	int idx = blockIdx.x * blockDim.x + threadIdx.x;

	if (idx < patternLen - 1)
	{
		int cnt = 0;
		int j = idx;
		int k = patternLen - 1;

		while (j >= 0 && sharedPattern[j] == sharedPattern[k])
		{
			++cnt;
			--j;
			--k;
		}

		if (cnt > 0)
		{
			// ͳ�Ƴ��Ӵ�[0,idx]��ģʽ����׺���ƥ�䳤��֮��
			// �������бȽϲ�ִ��ԭ��д�룬����ȴ�maxSuffixȫ���������
			// ģʽ�����Ƚ�С��ʹ��˽��ԭ�Ӳ�����������
			atomicMax(goodSuffix + patternLen - cnt, idx);
		}
	}
}

void __global__ bmKernel(const char* __restrict__ text, const int textLen, const int threadTextLen, const char* __restrict__ pattern, const int patternLen, const int* __restrict__ badChar, const int* __restrict__ goodSuffix, int* matchNum, int* matchIdx)
{
	// ����ÿ���̶߳�������һ���ı��������ڴ��޷�����ÿ��block���账���ı����ʲ����ı����ؽ������ڴ�
	// ����block�����ı���������ƥ����Ҳ�ϴ󣬹��޷�����˽�л�ԭ�Ӳ���
	__shared__ int sharedBadChar[ALPHABET_SIZE];
	extern __shared__ char sharedMemory[];
	int* sharedGoodSuffix = (int*)(sharedMemory);
	char* sharedPattern = (char*)(sharedGoodSuffix + patternLen);

	int perThreadBadCharLen = ceil(ALPHABET_SIZE * 1.0 / blockDim.x);
	int perThreadPatternLen = ceil(patternLen * 1.0 / blockDim.x);

	for (int i = threadIdx.x * perThreadBadCharLen; i < (threadIdx.x + 1) * perThreadBadCharLen && i < ALPHABET_SIZE; ++i)
	{
		sharedBadChar[i] = badChar[i];
	}

	for (int i = threadIdx.x * perThreadPatternLen; i < (threadIdx.x + 1) * perThreadPatternLen && i < patternLen; ++i)
	{
		sharedPattern[i] = pattern[i];
		sharedGoodSuffix[i] = goodSuffix[i];
	}

	__syncthreads();

	// Ϊȷ���ҵ�����ƥ�䣬ÿ���̶߳�����ģʽ������-1���ַ�
	int extendedThreadTextLen = threadTextLen + patternLen - 1;
	int textIdx = (blockIdx.x * blockDim.x + threadIdx.x) * threadTextLen;
	int i = patternLen - 1;

	while (i < extendedThreadTextLen && textIdx + i < textLen)
	{
		int j = patternLen - 1;
		int k = i;
		int len = 0;
		
		while (j >= 0 && text[textIdx + k] == sharedPattern[j])
		{
			--k;
			--j;
		}

		if (j < 0)
		{
			++k;
			int idx = atomicAdd(matchNum, 1);
			matchIdx[idx] = textIdx + k;
			++i;
		}
		else
		{
			int largestGoodSuffixPos = -1;
			int offset = __max(1, j - sharedBadChar[text[textIdx + k]]);

			for (int l = j + 1; l < patternLen - 1; ++l)
			{
				if (sharedGoodSuffix[l] != -1)
				{
					offset = __max(offset, patternLen - 1 - sharedGoodSuffix[l]);
					break;
				}
			}

			i += offset;
		}
	}
}

void bmBuildGpu(int** badCharDevPtr, int** goodSuffixDevPtr)
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(patternLen * 1.0 / blockSize.x);

	cudaMalloc(badCharDevPtr, sizeof(int) * ALPHABET_SIZE);
	cudaMemset(*badCharDevPtr, 0xff, sizeof(int) * ALPHABET_SIZE);
	bmBadCharKernel <<< gridSize, blockSize >>> (patternDev, patternLen, *badCharDevPtr);
	
	cudaMalloc(goodSuffixDevPtr, sizeof(int) * patternLen);
	cudaMemset(*goodSuffixDevPtr, 0xff, sizeof(int) * patternLen);
	bmGoodSuffixKernel <<< gridSize, blockSize, patternLen >>> (patternDev, patternLen, *goodSuffixDevPtr);	
}

void bmGpu()
{
	dim3 blockSize = blockLen;
	dim3 gridSize = ceil(textLen * 1.0 / (blockSize.x * threadTextLen));

	int* matchNumDev = nullptr;
	int* matchIdxDev = nullptr;
	patternMatchGpuMalloc(&matchNumDev, &matchIdxDev);

	int* badCharDev = nullptr;
	int* goodSuffixDev = nullptr;
	bmBuildGpu(&badCharDev, &goodSuffixDev);

	bmKernel <<< gridSize, blockSize, patternLen * (sizeof(char) + sizeof(int)) >>> (textDev, textLen, threadTextLen, patternDev, patternLen, badCharDev, goodSuffixDev, matchNumDev, matchIdxDev);

#ifdef PRINT
	printMatchOutputGpu(matchNumDev, matchIdxDev);
#endif

	cudaFree(badCharDev);
	cudaFree(goodSuffixDev);
	patternMatchGpuFree(matchNumDev, matchIdxDev);
}
