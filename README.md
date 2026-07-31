# Deploy Kimi K3 lên GCP (Spot VM, dùng theo phiên)

Bộ script deploy [Kimi K3](https://unsloth.ai/docs/models/kimi-k3) (2.8T params, 104B active, MoE + vision)
lên Google Cloud bằng Spot VM, tối ưu cho kiểu **dùng theo phiên** (bật khi cần, tắt khi xong).

## Cấu hình hạ tầng

| Thành phần | Lựa chọn | Lý do |
|---|---|---|
| Machine type | `a2-highgpu-8g` (8× A100 40GB, 96 vCPU, 680GB RAM) | 1,000GB RAM+VRAM — đủ cho quant 594GB. Chọn thay `a2-ultragpu-4g` (cùng tổng 1,000GB) vì quota A100 40GB thường có sẵn, còn A100 80GB hay bằng 0 |
| Provisioning | Spot VM | Rẻ hơn ~70-80% so với on-demand |
| Lưu model | GCS bucket → local SSD mỗi phiên | GCS ~$12/tháng vs persistent disk ~$90-153/tháng |
| Inference + UI | [Unsloth Studio](https://unsloth.ai/docs/new/studio) | Web UI có sẵn để test; đã bundle llama.cpp fork hỗ trợ K3 nên khỏi build từ source |

## Chi phí ước tính

- **Lúc chạy**: ~$4-6/giờ (Spot)
- **Lúc không dùng**: ~$32/tháng (boot disk 200GB + model trên GCS)

> Số Spot là ước tính suy ra từ giá A100 80GB per-GPU. Xác nhận lại bằng
> [GCP Pricing Calculator](https://cloud.google.com/products/calculator) trước khi chạy phiên dài.

## Cách dùng

### Setup ban đầu (một lần)

```bash
# 1. Sửa config cho đúng project của bạn
vim 00-config.sh

# 2. Tạo bucket + Spot VM
./01-provision.sh

# 3. Copy script lên VM rồi cài Unsloth Studio + tải model (~600GB, mất khá lâu)
gcloud compute scp 02-setup-vm.sh lib-mount-localssd.sh kimi-k3-vm:~/ --zone=us-central1-a
gcloud compute ssh kimi-k3-vm --zone=us-central1-a
#    trên VM:
export BUCKET=gs://<PROJECT_ID>-kimi-k3-models QUANT=UD-IQ1_S
bash ~/02-setup-vm.sh
```

### Mỗi phiên làm việc

```bash
./03-start-session.sh    # start VM, restore model, mở Unsloth Studio tại http://localhost:8888
# ... test trong UI ...
./04-stop-session.sh     # LUÔN chạy khi xong, nếu không sẽ bị tính tiền GPU
```

### Dùng UI

Mở `http://localhost:8888`, chọn model `Kimi-K3-GGUF` (Studio tự phát hiện model
trong HF cache tại `/mnt/localssd/hf`). Trong phần **GGUF hardware controls** có thể chỉnh:

- GPU/layer placement
- **Offload MoE experts** sang CPU RAM (thay cho việc phải tự tune `--n-cpu-moe` bằng tay)
- Multi-GPU / Tensor Parallelism

Context size không cần chỉnh tay — llama.cpp có smart auto context.
Temperature/top-p được preset sẵn theo model.

Studio cũng expose OpenAI-compatible API endpoint nếu bạn muốn gọi từ code
thay vì dùng UI (xem [docs](https://unsloth.ai/docs/basics/api)).

## Cần xử lý trước khi chạy

1. **Quota** — `01-provision.sh` có preflight check, tự báo thiếu cái nào. Cần tại `us-central1`:

   | Metric | Cần |
   |---|---|
   | `PREEMPTIBLE_NVIDIA_A100_GPUS` | ≥ 8 |
   | `PREEMPTIBLE_CPUS` | ≥ 96 |

   Quota Spot (`PREEMPTIBLE_*`) tách riêng quota on-demand.

   > **Bẫy:** `gcloud compute regions describe` (API legacy) báo
   > `PREEMPTIBLE_LOCAL_SSD_GB = 0`, nhưng đó không phải quota thật.
   > Quota local SSD là **zonal** và mặc định **unlimited**. Kiểm tra bằng:
   > ```bash
   > gcloud beta quotas info describe PREEMPTIBLE-LOCAL-SSD-GB-per-project-zone \
   >   --service=compute.googleapis.com --project=<PROJECT_ID>
   > ```
   > `value: '-1'` nghĩa là unlimited.

2. **Verify tên thư mục quant** — repo Unsloth đã từng đổi tên
   (`UD-IQ1_S` ↔ `UD-IQ1_M` ↔ `UD-IQ2_XXS`). Kiểm tra
   [tree/main](https://huggingface.co/unsloth/Kimi-K3-GGUF/tree/main) rồi sửa `QUANT` trong `00-config.sh`.

3. **Chỉnh MoE offload trong UI** — 320GB VRAM không đủ chứa hết model 594GB, nên phải
   offload bớt expert sang RAM. Dùng "GGUF hardware controls" trong Studio, tăng mức offload
   dần cho tới khi load được mà không OOM (offload càng ít thì càng nhanh).
   Log trên VM: `tail -f ~/unsloth-studio.log`.

## Lựa chọn quant

| Quant | Size | RAM+VRAM cần | Ghi chú |
|---|---|---|---|
| UD-IQ1_S | 594 GB | ~610 GB | ~79% accuracy — khuyến nghị, vừa `a2-ultragpu-4g` |
| UD-IQ1_M | 649 GB | ~665 GB | |
| UD-Q2_K_XL | 861 GB | ~880 GB | ~90% accuracy, vẫn vừa 1,000GB |
| UD-Q8_K_XL | 1.56 TB | ~1.6 TB | Lossless — cần máy lớn hơn (a3-highgpu-8g) |

## Về Spot VM

- Google có thể thu hồi máy bất cứ lúc nào, cho ~30s để tắt gọn
- Không có SLA, không tự khởi động lại
- `--instance-termination-action=STOP` giữ VM lại (không xoá) khi bị preempt
- `--max-run-duration=8h` chốt trần, tránh quên tắt máy

Nếu sau này cần chạy service ổn định 24/7 thì chuyển sang on-demand hoặc
Committed Use Discount (cam kết 1-3 năm, giảm 25-57%) thay vì Spot.

## Phương án thay thế

Nếu không bắt buộc self-host (privacy, fine-tune riêng), dùng API trả theo token
thường rẻ và đơn giản hơn nhiều:

- **OpenRouter** (`moonshotai/kimi-k3`): $3/1M input, $15/1M output
- **Moonshot API trực tiếp**: $3/1M input (cache miss), $0.30/1M (cache hit)
