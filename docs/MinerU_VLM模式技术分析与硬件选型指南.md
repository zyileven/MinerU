# MinerU VLM 模式技术分析与硬件选型指南

> 文档版本：1.1
> 更新日期：2025-12-08
> 适用版本：MinerU 2.6.x + mineru_vl_utils 0.1.13

---

## 目录

1. [概述](#1-概述)
2. [三种处理模式对比](#2-三种处理模式对比)
3. [VLM 模式深度解析](#3-vlm-模式深度解析)
4. [MinerU2.5 模型详解](#4-mineru25-模型详解)
5. [推理引擎对比](#5-推理引擎对比)
6. [硬件资源规划](#6-硬件资源规划)
7. [部署建议](#7-部署建议)
8. [附录](#8-附录)

---

## 1. 概述

MinerU 是一个高质量的文档解析工具，支持将 PDF 文档转换为结构化的 Markdown 格式。系统提供三种处理模式：

| 模式 | 技术路线 | 特点 |
|-----|---------|------|
| **Pipeline** | 多模型串联 | 传统方案，模型分工明确 |
| **VLM-Transformers** | 视觉语言大模型 | 端到端处理，HuggingFace 推理 |
| **VLM-vLLM-Engine** | 视觉语言大模型 | 端到端处理，vLLM 高性能推理 |

本文档重点分析 VLM 模式的技术实现和硬件需求。

---

## 2. 三种处理模式对比

### 2.1 Pipeline 模式（多模型串联）

Pipeline 模式采用 **8 个专用模型** 串联处理文档：

```
PDF 输入
    ↓
┌─────────────────────────────────────────────────────────────┐
│  1. DocLayoutYOLO        布局检测（标题、文本、表格、图像等）  │
│  2. YOLOv8 MFD           数学公式位置检测                    │
│  3. Unimernet/ppFormula  公式识别 → LaTeX                   │
│  4. PytorchPaddleOCR     文字检测 + 识别                    │
│  5. PaddleTableCls       表格分类（有线/无线）               │
│  6. RapidTable           无线表格结构识别 → HTML             │
│  7. UnetTable            有线表格结构识别 → HTML             │
│  8. PaddleOrientationCls 图像方向分类                       │
└─────────────────────────────────────────────────────────────┘
    ↓
结构化 Markdown 输出
```

**Pipeline 模型清单：**

| 模型名称 | 任务职责 | 模型文件 | 显存占用 |
|---------|---------|---------|---------|
| DocLayoutYOLO | 布局检测 | doclayout_yolo | ~500MB |
| YOLOv8 MFD | 公式检测 | yolo_v8_mfd | ~200MB |
| Unimernet | 公式识别 | unimernet_small | ~1GB |
| PytorchPaddleOCR | OCR | PaddleOCR 系列 | ~500MB |
| PaddleTableCls | 表格分类 | table_cls | ~100MB |
| RapidTable | 无线表格 | slanet_plus | ~200MB |
| UnetTable | 有线表格 | unet_table | ~200MB |
| PaddleOrientationCls | 方向分类 | orientation_cls | ~100MB |

**Pipeline 模式显存需求：约 3-4GB**

### 2.2 VLM 模式（视觉语言大模型）

VLM 模式使用 **MinerU2.5-2509-1.2B 专用模型** 完成所有任务：

```
PDF 输入
    ↓
┌─────────────────────────────────────────────────────────────┐
│                  MinerU2.5-2509-1.2B                         │
│        (基于 Qwen2-VL 微调的文档解析专用模型)                  │
│                                                              │
│  功能：布局检测 + 文本识别 + 表格识别 + 公式识别              │
└─────────────────────────────────────────────────────────────┘
    ↓
结构化 Markdown 输出
```

**VLM 模式显存需求：1.2B 模型约 3-4GB（BF16）**

### 2.3 模式对比总结

| 对比维度 | Pipeline | VLM-Transformers | VLM-vLLM-Engine |
|---------|----------|------------------|-----------------|
| 模型数量 | 8 个专用模型 | 1 个专用模型 | 1 个专用模型 |
| 模型参数量 | 总计约 3B | **1.2B** | **1.2B** |
| 显存需求 | ~4GB | **~4GB** | **~4GB** |
| 处理速度 | 中等 | 较慢 | **快 (2.12 fps @ A100)** |
| 部署复杂度 | 较高 | 中等 | 中等 |
| 准确率 | 高（各模型专精） | 高（端到端理解） | 高（端到端理解） |
| 适用场景 | 资源受限环境 | 开发测试 | 生产部署 |

---

## 3. VLM 模式深度解析

### 3.1 核心组件

VLM 模式的核心由 `mineru_vl_utils` 包提供：

```
mineru_vl_utils/
├── __init__.py              # 入口，导出 MinerUClient
├── mineru_client.py         # 核心客户端实现
├── structs.py               # 数据结构定义（21种块类型）
├── vlm_client/              # 推理后端实现
│   ├── base_client.py       # 基类和采样参数
│   ├── transformers_client.py  # HuggingFace 后端
│   ├── vllm_engine_client.py   # vLLM 同步后端
│   ├── vllm_async_engine_client.py  # vLLM 异步后端
│   └── http_client.py       # HTTP API 后端
├── logits_processor/        # 自定义采样器
│   └── vllm_v1_no_repeat_ngram.py
└── post_process/            # 后处理逻辑
```

### 3.2 两步推理流程

VLM 模式执行 **两步推理** 处理文档：

```
┌─────────────────────────────────────────────────────────────┐
│                    两步推理流程                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Step 1: 布局检测 (Layout Detection)                        │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 输入：页面图像 (缩放至 1036×1036)                    │     │
│  │ 提示词："\nLayout Detection:"                       │     │
│  │ 输出：块类型 + 边界框 + 旋转角度                     │     │
│  │                                                     │     │
│  │ 输出格式：                                          │     │
│  │ <|box_start|>x1 y1 x2 y2<|box_end|>                │     │
│  │ <|ref_start|>block_type<|ref_end|>                 │     │
│  │ <|rotate_up|>                                       │     │
│  └────────────────────────────────────────────────────┘     │
│                          ↓                                   │
│  Step 2: 内容提取 (Content Extraction)                      │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 输入：裁剪后的块图像 (根据角度旋转)                  │     │
│  │ 提示词：根据块类型选择                              │     │
│  │   - 表格: "\nTable Recognition:"                   │     │
│  │   - 公式: "\nFormula Recognition:"                 │     │
│  │   - 文本: "\nText Recognition:"                    │     │
│  │ 输出：具体内容（文本/LaTeX/HTML）                   │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 支持的块类型（21 种）

| 类型 | 英文标识 | 描述 |
|-----|---------|------|
| 文本 | text | 普通正文文本 |
| 标题 | title | 段落标题 |
| 表格 | table | 表格内容 |
| 图像 | image | 图片区域 |
| 代码 | code | 代码块 |
| 算法 | algorithm | 算法/伪代码 |
| 公式 | equation | 独立数学公式 |
| 公式块 | equation_block | 多行公式块 |
| 页眉 | header | 页面页眉 |
| 页脚 | footer | 页面页脚 |
| 页码 | page_number | 页码 |
| 脚注 | page_footnote | 页面脚注 |
| 侧栏文本 | aside_text | 装订线等侧栏 |
| 参考文献 | ref_text | 参考文献条目 |
| 列表 | list | 有序/无序列表 |
| 注音 | phonetic | 注音符号 |
| 表格标题 | table_caption | 表格标题 |
| 图像标题 | image_caption | 图像标题 |
| 代码标题 | code_caption | 代码标题 |
| 表格脚注 | table_footnote | 表格脚注 |
| 图像脚注 | image_footnote | 图像脚注 |

### 3.4 采样参数配置

```python
# 默认采样参数
class MinerUSamplingParams:
    temperature: float = 0.0       # 温度（0=贪婪解码）
    top_p: float = 0.01            # nucleus sampling 阈值
    top_k: int = 1                 # top-k 采样
    presence_penalty: float = 0.0  # 存在惩罚
    frequency_penalty: float = 0.0 # 频率惩罚
    repetition_penalty: float = 1.0 # 重复惩罚
    no_repeat_ngram_size: int = 100 # 禁止重复的 n-gram 大小

# 不同任务的参数调整
任务类型        | presence_penalty | frequency_penalty
---------------|------------------|------------------
布局检测        | 0.0              | 0.0
表格识别        | 1.0              | 0.005
公式识别        | 1.0              | 0.05
文本识别        | 1.0              | 0.05
```

---

## 4. MinerU2.5 模型详解

### 4.1 模型基本信息

MinerU VLM 模式使用的是 **OpenDataLab 专门为文档解析微调的模型**，而非通用的 Qwen2-VL 模型。

**模型仓库配置（源码 `mineru/utils/enum_class.py`）：**

```python
class ModelPath:
    vlm_root_hf = "opendatalab/MinerU2.5-2509-1.2B"
    vlm_root_modelscope = "OpenDataLab/MinerU2.5-2509-1.2B"
```

### 4.2 MinerU2.5-2509-1.2B 模型规格

| 属性 | 值 |
|-----|-----|
| **模型名称** | MinerU2.5-2509-1.2B |
| **发布机构** | OpenDataLab |
| **参数量** | **1.2B（12 亿参数）** |
| **基础模型** | Qwen2-VL（经专门微调） |
| **数据格式** | BF16 (Safetensors) |
| **许可证** | AGPL-3.0 |
| **任务类型** | Image-Text-to-Text |

### 4.3 与通用 Qwen2-VL 系列对比

| 模型 | 参数量 | 用途 | 显存需求 (BF16) |
|-----|-------|------|----------------|
| **MinerU2.5-2509-1.2B** | **1.2B** | **MinerU 文档解析专用** | **~3-4GB** |
| Qwen2-VL-2B | 2.2B | 通用视觉理解 | ~5GB |
| Qwen2-VL-7B | 8.3B | 通用视觉理解 | ~16GB |
| Qwen2-VL-72B | 73B | 通用视觉理解 | ~150GB |

**关键结论：MinerU VLM 使用的是 1.2B 小模型，资源需求远低于通用大模型。**

### 4.4 模型架构

MinerU2.5 基于 Qwen2-VL 架构，针对文档解析任务进行了专门优化：

```
┌─────────────────────────────────────────────────────────────┐
│                  MinerU2.5-2509-1.2B 架构                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │           Vision Encoder (ViT)                      │     │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │     │
│  │  │ Patch        │→ │ Window       │→ │ Full     │  │     │
│  │  │ Embedding    │  │ Attention    │  │ Attention│  │     │
│  │  │ (14×14 patch)│  │ (8×8 窗口)    │  │ (4层)    │  │     │
│  │  └──────────────┘  └──────────────┘  └──────────┘  │     │
│  │                                                     │     │
│  │  位置编码: 2D-RoPE (二维旋转位置编码)                │     │
│  │  激活函数: SwiGLU                                   │     │
│  │  归一化: RMSNorm                                    │     │
│  └────────────────────────────────────────────────────┘     │
│                          ↓                                   │
│  ┌────────────────────────────────────────────────────┐     │
│  │              Cross-Modal Projector                  │     │
│  │         (视觉特征 → 语言模型空间映射)                 │     │
│  └────────────────────────────────────────────────────┘     │
│                          ↓                                   │
│  ┌────────────────────────────────────────────────────┐     │
│  │           Language Model (~1.2B 参数)               │     │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │     │
│  │  │ Token        │→ │ Transformer  │→ │ Output   │  │     │
│  │  │ Embedding    │  │ Decoder      │  │ Head     │  │     │
│  │  └──────────────┘  └──────────────┘  └──────────┘  │     │
│  │                                                     │     │
│  │  位置编码: M-RoPE (多模态旋转位置编码)               │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.5 模型特点与优势

1. **专门优化**：针对文档解析任务微调，在该任务上性能优异
2. **高效轻量**：1.2B 参数，普通消费级 GPU 即可运行
3. **两阶段解析**：
   - 第一阶段：下采样图像全局布局分析
   - 第二阶段：原始分辨率细粒度识别
4. **核心能力**：
   - 全面布局分析（保留页眉、页脚、页码等）
   - 复杂公式解析（支持中英混合）
   - 强大表格识别（旋转表、无边框表等）

### 4.6 官方性能数据

| 指标 | 数据 |
|-----|------|
| 推理速度 (A100) | **2.12 fps** 并发推理 |
| 基准测试 | OmniDocBench SOTA |
| 模型大小 | ~2.5GB (BF16) |

---

## 5. 推理引擎对比

### 5.1 Transformers 后端

使用 HuggingFace Transformers 进行原生 PyTorch 推理：

```python
# 初始化
from transformers import Qwen2VLForConditionalGeneration, AutoProcessor

model = Qwen2VLForConditionalGeneration.from_pretrained(
    "opendatalab/MinerU2.5-2509-1.2B",
    device_map="auto",
    torch_dtype="auto",
)
processor = AutoProcessor.from_pretrained(
    "opendatalab/MinerU2.5-2509-1.2B",
    use_fast=True
)

# 推理
inputs = processor(text=prompts, images=images, return_tensors="pt")
output_ids = model.generate(**inputs, use_cache=True, **generate_kwargs)
```

**特点：**
- 实现简单，易于调试
- 显存占用相对较高
- 批处理效率一般
- 适合开发测试环境

### 5.2 vLLM 后端

使用 vLLM 高性能推理引擎：

```python
# 初始化
from vllm import LLM
from mineru_vl_utils import MinerUClient

llm = LLM(
    model="opendatalab/MinerU2.5-2509-1.2B",
    gpu_memory_utilization=0.7,
)

client = MinerUClient(backend="vllm-engine", vllm_llm=llm)

# 推理
extracted_blocks = client.two_step_extract(image)
```

**特点：**
- PagedAttention 动态显存管理
- 连续批处理 (Continuous Batching)
- 高并发支持
- 适合生产部署环境

### 5.3 性能对比

| 特性 | Transformers | vLLM-Engine |
|-----|-------------|-------------|
| 推理引擎 | PyTorch 原生 | vLLM 优化引擎 |
| KV Cache 管理 | 静态分配 | PagedAttention 动态分页 |
| 批处理方式 | 静态批处理 | 连续批处理 |
| GPU 显存利用率 | ~50% | ~70% (可配置) |
| 并发请求支持 | 有限 | 高并发 |
| 量化支持 | 有限 | AWQ/GPTQ/FP8 等 |
| 首次启动时间 | 快 | 需要编译，较慢 |
| 吞吐量 | 基准 | **2-3 倍提升** |

### 5.4 vLLM 特有优化

**自定义 Logits Processor（防止重复输出）：**

```python
class VllmV1NoRepeatNGramLogitsProcessor(LogitsProcessor):
    """
    防止输出中重复相同的 n-gram
    """
    def apply(self, logits: torch.Tensor) -> torch.Tensor:
        for index in range(len(logits)):
            no_repeat_ngram_size = ...  # 默认 100

            # 获取当前前缀
            current_prefix = tuple(output_tok_ids[-no_repeat_ngram_size + 1:])

            # 查找已出现的 n-gram
            banned_tokens = cached_ngrams.get(current_prefix, [])

            # 禁止重复 token
            for token in banned_tokens:
                logits[index][token] = -float("inf")

        return logits
```

**启用条件：**
- GPU Compute Capability >= 8.0 (Ampere 架构及以上)
- vLLM 版本 >= 0.10.1
- 环境变量 `VLLM_USE_V1=1` (默认启用)

---

## 6. 硬件资源规划

### 6.1 显存需求分析

#### MinerU2.5-2509-1.2B 显存需求

| 精度 | 模型显存 | 运行时显存 | 推荐 GPU |
|-----|---------|----------|---------|
| BF16/FP16 | ~2.5GB | **~3-4GB** | RTX 3060 12GB |
| INT8 量化 | ~1.5GB | ~2-3GB | RTX 3050 8GB |
| INT4 量化 | ~0.8GB | ~1.5-2GB | GTX 1660 6GB |

#### 运行时显存占用（含 KV Cache）

| 批处理大小 | Transformers | vLLM |
|-----------|-------------|------|
| batch_size=1 | ~4GB | ~3GB |
| batch_size=4 | ~5GB | ~4GB |
| batch_size=8 | ~6GB | ~5GB |

#### MinerU 代码中的配置

```python
# 显存利用率配置 (vlm/utils.py)
def set_default_gpu_memory_utilization():
    if vllm_version >= "0.11.0":
        return 0.7   # 使用 70% GPU 显存
    else:
        return 0.5   # 使用 50% GPU 显存

# 批处理大小配置
def set_default_batch_size():
    if gpu_memory >= 16GB:
        batch_size = 8
    elif gpu_memory >= 8GB:
        batch_size = 4
    else:
        batch_size = 1
```

### 6.2 GPU 架构要求

| GPU 架构 | Compute Capability | 代表型号 | vLLM 支持级别 |
|---------|-------------------|---------|--------------|
| Pascal | 6.1 | GTX 10xx | ✅ 基础支持 |
| Volta | 7.0 | V100 | ✅ 基础支持 |
| Turing | 7.5 | RTX 20xx, T4 | ✅ 基础支持 |
| Ampere | 8.0 | A100, RTX 30xx | ✅ 完整支持 |
| Ada Lovelace | 8.9 | RTX 40xx, L40 | ✅ 完整支持 |
| Hopper | 9.0 | H100, H200 | ✅ 最佳支持 |

**注意：** vLLM 的 `MinerULogitsProcessor` 需要 Compute Capability >= 8.0

### 6.3 不同场景配置推荐

#### 场景一：开发测试 / 个人使用

```
┌─────────────────────────────────────────────────────────────┐
│  场景：开发测试 / 小规模处理                                  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  【入门配置】 ★ 推荐入门用户                                  │
│  ├─ GPU: NVIDIA RTX 3060 12GB                               │
│  ├─ CPU: Intel i5-12400 / AMD R5 5600X                      │
│  ├─ 内存: 16GB DDR4                                         │
│  ├─ 存储: 256GB NVMe SSD                                    │
│  ├─ 预算: ¥5,000 - ¥8,000                                   │
│  ├─ 适用: VLM 模式 (1.2B 模型)                               │
│  └─ 性能: ~1-2 页/秒                                         │
│                                                              │
│  【标准配置】                                                 │
│  ├─ GPU: NVIDIA RTX 4060 Ti 16GB                            │
│  ├─ CPU: Intel i5-13400 / AMD R5 7600                       │
│  ├─ 内存: 32GB DDR5                                         │
│  ├─ 存储: 512GB NVMe SSD                                    │
│  ├─ 预算: ¥8,000 - ¥12,000                                  │
│  ├─ 适用: VLM 模式 + vLLM-Engine                            │
│  └─ 性能: ~2-4 页/秒                                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

#### 场景二：中小企业生产环境

```
┌─────────────────────────────────────────────────────────────┐
│  场景：中小企业 / 日处理量 1,000-10,000 页                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  【性价比配置】 ★ 推荐中小企业                                │
│  ├─ GPU: NVIDIA RTX 4090 24GB                               │
│  ├─ CPU: Intel i7-13700K / AMD R7 7800X                     │
│  ├─ 内存: 64GB DDR5                                         │
│  ├─ 存储: 1TB NVMe SSD                                      │
│  ├─ 预算: ¥25,000 - ¥35,000                                 │
│  ├─ 适用: VLM 模式 + vLLM 高并发                             │
│  └─ 性能: ~5-8 页/秒                                         │
│                                                              │
│  【专业配置】                                                 │
│  ├─ GPU: NVIDIA L4 24GB 或 T4 16GB × 2                      │
│  ├─ CPU: Intel Xeon W-2245 / AMD EPYC 7313                  │
│  ├─ 内存: 128GB DDR4 ECC                                    │
│  ├─ 存储: 2TB NVMe SSD                                      │
│  ├─ 预算: ¥40,000 - ¥60,000                                 │
│  ├─ 适用: 多实例部署                                         │
│  └─ 性能: ~10-15 页/秒                                       │
│                                                              │
│  【计算资源估算】                                             │
│  ├─ 日处理 5,000 页                                          │
│  ├─ 单页处理时间: ~0.15 秒 (6-7 页/秒)                       │
│  ├─ 日运行时间: ~750 秒 ≈ 12.5 分钟                          │
│  └─ 可支持突发流量和并发请求                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

#### 场景三：大型企业 / 高并发生产环境

```
┌─────────────────────────────────────────────────────────────┐
│  场景：大型企业 / 日处理量 10,000+ 页                         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  【高性能配置】                                               │
│  ├─ GPU: NVIDIA A10 24GB × 2 或 A100 40GB                   │
│  ├─ CPU: Intel Xeon Gold 6348 / AMD EPYC 7543               │
│  ├─ 内存: 256GB DDR4 ECC                                    │
│  ├─ 存储: 4TB NVMe SSD RAID                                 │
│  ├─ 预算: ¥100,000 - ¥200,000                               │
│  ├─ 适用: 高并发多实例                                       │
│  └─ 性能: ~20-40 页/秒                                       │
│                                                              │
│  【旗舰集群配置】                                             │
│  ├─ GPU: NVIDIA L40 48GB × 4 或 A100 80GB × 2               │
│  ├─ CPU: Intel Xeon Platinum 8480+ / AMD EPYC 9654          │
│  ├─ 内存: 512GB+ DDR5 ECC                                   │
│  ├─ 存储: 高速 NVMe 阵列                                     │
│  ├─ 网络: 100GbE                                            │
│  ├─ 预算: ¥300,000 - ¥600,000                               │
│  ├─ 适用: 超高并发 / 多租户服务                              │
│  └─ 性能: ~100+ 页/秒                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.4 云服务方案

| 云厂商 | 实例类型 | GPU 配置 | 按需价格 | 适用场景 |
|-------|---------|---------|---------|---------|
| **AWS** | g4dn.xlarge | T4 16GB | ~$0.5/小时 | 入门测试 |
| **AWS** | g5.xlarge | A10G 24GB | ~$1.0/小时 | 生产部署 |
| **阿里云** | ecs.gn6i-c4g1.xlarge | T4 16GB | ~¥8/小时 | 入门测试 |
| **阿里云** | ecs.gn7i-c8g1.2xlarge | A10 24GB | ~¥15/小时 | 生产部署 |
| **腾讯云** | GN7.LARGE20 | T4 16GB | ~¥10/小时 | 入门测试 |
| **华为云** | p2s.large | T4 16GB | ~¥12/小时 | 生产部署 |

**云服务成本估算（日处理 1000 页）：**
- T4 实例：~¥2-3/天（约 15-20 分钟运行时间）
- A10 实例：~¥3-5/天（约 10-15 分钟运行时间）

### 6.5 GPU 选型决策树

```
                    ┌─────────────────┐
                    │  日处理量估算    │
                    └────────┬────────┘
                             │
           ┌─────────────────┼─────────────────┐
           │                 │                 │
           ▼                 ▼                 ▼
    ┌──────────┐      ┌──────────┐      ┌──────────┐
    │ < 1000页 │      │1000-5000页│     │ > 5000页 │
    └────┬─────┘      └────┬─────┘      └────┬─────┘
         │                 │                 │
         ▼                 ▼                 ▼
    ┌──────────┐      ┌──────────┐      ┌──────────┐
    │RTX 3060  │      │ RTX 4090 │      │ A10/L4   │
    │  12GB    │      │  24GB    │      │ 多实例   │
    └────┬─────┘      └────┬─────┘      └────┬─────┘
         │                 │                 │
         ▼                 ▼                 ▼
    ┌──────────┐      ┌──────────┐      ┌──────────┐
    │~1-2页/秒 │      │~5-8页/秒 │      │~20+页/秒 │
    │ ¥0.5万   │      │ ¥2.5万   │      │ ¥5-10万  │
    └──────────┘      └──────────┘      └──────────┘
```

---

## 7. 部署建议

### 7.1 模式选择建议

| 场景 | 推荐模式 | 理由 |
|-----|---------|------|
| 显存受限 (< 4GB) | Pipeline | 多模型分时加载 |
| 普通 GPU (4-8GB) | VLM-Transformers | 1.2B 模型显存需求低 |
| 生产部署 | VLM-vLLM-Engine | 高性能，高并发 |
| 边缘设备 | VLM (INT4 量化) | 量化后 <2GB 显存 |
| 批量处理 | VLM-vLLM-Engine | 连续批处理效率高 |

### 7.2 环境变量配置

```bash
# vLLM 相关
export VLLM_USE_V1=1                    # 启用 vLLM v1 API
export OMP_NUM_THREADS=1                # OpenMP 线程数

# MinerU 相关
export MINERU_MODEL_SOURCE=huggingface  # 模型源 (huggingface/modelscope/local)
export MINERU_VIRTUAL_VRAM_SIZE=12      # 虚拟显存大小 (GB)
export MINERU_FORMULA_CH_SUPPORT=false  # 中文公式支持

# LMDeploy 相关 (如使用)
export MINERU_LMDEPLOY_DEVICE=cuda      # 设备类型
export MINERU_LMDEPLOY_BACKEND=pytorch  # 后端类型
```

### 7.3 性能优化建议

1. **显存优化**
   - 使用 vLLM 的 PagedAttention
   - 合理设置 `gpu_memory_utilization` (推荐 0.7)
   - 考虑使用量化模型 (INT8/INT4)

2. **吞吐量优化**
   - 启用连续批处理
   - 根据显存调整 batch_size
   - 使用异步推理 (vllm-async-engine)

3. **延迟优化**
   - 预热模型，避免首次推理延迟
   - 使用 SSD 存储模型文件
   - 优化图像预处理流程

### 7.4 监控指标

| 指标 | 描述 | 建议阈值 |
|-----|------|---------|
| GPU 利用率 | GPU 计算单元使用率 | > 70% |
| 显存使用率 | GPU 显存占用 | < 85% |
| 处理延迟 | 单页处理时间 | < 0.5s (1.2B 模型) |
| 吞吐量 | 每秒处理页数 | 根据配置 |
| 错误率 | 处理失败比例 | < 1% |

---

## 8. 附录

### 8.1 关键文件索引

**MinerU VLM 模式核心文件：**

| 文件路径 | 功能 |
|---------|------|
| `mineru/backend/vlm/vlm_analyze.py` | VLM 主分析入口 |
| `mineru/backend/vlm/utils.py` | 配置工具函数 |
| `mineru/backend/vlm/vlm_magic_model.py` | 结果结构化处理 |
| `mineru/model/vlm/vllm_server.py` | vLLM 服务器启动 |
| `mineru/utils/enum_class.py` | 模型路径定义 |

**mineru_vl_utils 包文件：**

| 文件路径 | 功能 |
|---------|------|
| `mineru_vl_utils/mineru_client.py` | 核心客户端 |
| `mineru_vl_utils/vlm_client/transformers_client.py` | Transformers 后端 |
| `mineru_vl_utils/vlm_client/vllm_engine_client.py` | vLLM 后端 |
| `mineru_vl_utils/logits_processor/` | 自定义采样器 |

### 8.2 常用命令

```bash
# 下载 VLM 模型
mineru-models-download vlm

# 使用 VLM-Transformers 模式
mineru -p input.pdf -o output/ --backend vlm-transformers

# 使用 VLM-vLLM-Engine 模式
mineru -p input.pdf -o output/ --backend vlm-vllm-engine

# 启动 vLLM 服务器
python -m mineru.model.vlm.vllm_server

# 指定 GPU
CUDA_VISIBLE_DEVICES=0 mineru -p input.pdf -o output/ --backend vlm-vllm-engine

# 使用 ModelScope 源下载（国内用户）
MINERU_MODEL_SOURCE=modelscope mineru-models-download vlm
```

### 8.3 参考资源

- [MinerU2.5-2509-1.2B HuggingFace](https://huggingface.co/opendatalab/MinerU2.5-2509-1.2B)
- [MinerU GitHub 仓库](https://github.com/opendatalab/MinerU)
- [Qwen2-VL 官方博客](https://qwenlm.github.io/blog/qwen2-vl/)
- [vLLM 官方文档](https://docs.vllm.ai/)

---

## 文档更新记录

| 版本 | 日期 | 更新内容 |
|-----|------|---------|
| 1.0 | 2025-12-08 | 初始版本 |
| 1.1 | 2025-12-08 | 修正模型信息：MinerU 使用 MinerU2.5-2509-1.2B 专用模型（1.2B 参数），而非通用 Qwen2-VL 7B/72B；大幅下调硬件配置建议 |

---

*本文档基于 MinerU 源码分析和官方模型文档整理，仅供技术参考。*
