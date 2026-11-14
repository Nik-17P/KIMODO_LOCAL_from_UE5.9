@echo off
chcp 65001 >nul
setlocal

set "PYTHON_EXE=%~dp0Intermediate\PipInstall\Scripts\python.exe"

if not exist "%PYTHON_EXE%" (
    echo [ERROR] Python не найден.
    echo Включите "Python Editor Script Plugin" в настройках Unreal Engine, перезапустите проект и попробуйте снова.
    pause
    exit /b 1
)

echo =======================================================
echo ЗАПУСК ПОЛНОЙ УСТАНОВКИ KIMODO (АВТОМАТИЧЕСКИЙ РЕЖИМ)
echo =======================================================
echo [INFO] Генерация установочного скрипта...

set "TEMP_PY=%TEMP%\setup_kimodo_final.py"

:: Создаем Python скрипт через PowerShell (это 100% защищает от ошибок экранирования CMD)
powershell -Command "$py = @'
import os, sys, subprocess, ssl, shutil

# Отключаем проверку SSL для скачивания моделей
ssl._create_default_https_context = ssl._create_unverified_context

# ==========================================================
# ВАЖНО: Укажите здесь путь к вашему Unreal Engine!
# ==========================================================
ENGINE_DIR = r"D:\Unreal_Engine\UE_5.9"
MODEL_DIR = r"D:\Kimodo_Models"
# ==========================================================

KIMODO_LIB = os.path.join(ENGINE_DIR, "Engine", "Plugins", "Experimental", "Animation", "Kimodo", "Content", "Python", "kimodo", "kimodo")
PYTHON_EXE = sys.executable

print("=== [1/4] Установка зависимостей (PyTorch 2.7.1, bitsandbytes и др.) ===")
print("-> Установка PyTorch (может занять несколько минут)...")
subprocess.check_call([PYTHON_EXE, "-m", "pip", "install", "torch==2.7.1", "torchvision==0.22.1", "torchaudio==2.7.1", "--index-url", "https://download.pytorch.org/whl/cu128"])
print("-> Установка BitsAndBytes (для 4-битного режима NF4)...")
subprocess.check_call([PYTHON_EXE, "-m", "pip", "install", "--extra-index-url", "https://jllllll.github.io/bitsandbytes-windows-webui", "bitsandbytes>=0.46.1"])
print("-> Установка остальных библиотек Kimodo...")
subprocess.check_call([PYTHON_EXE, "-m", "pip", "install", "python-certifi-win32", "huggingface-hub<2.0", "transformers==5.1.0", "peft>=0.18", "numpy<2", "scipy<2", "hydra-core>=1.3", "omegaconf>=2.3", "boto3", "einops", "tqdm", "packaging", "pydantic", "filelock", "trimesh", "scenepic", "pillow", "av", "bvhio", "gradio>=6.8.0", "gradio_client>=1.0"])

print("\n=== [2/4] Скачивание моделей ===")
from huggingface_hub import snapshot_download
print("-> Скачивание основной модели Kimodo-SOMA (1.1 ГБ)...")
main_model_path = snapshot_download(repo_id="nvidia/Kimodo-SOMA-RP-v1.1", cache_dir=os.path.join(MODEL_DIR, "HF_Cache"))
print("-> Скачивание текстового энкодера NF4...")
text_encoder_path = snapshot_download(repo_id="Aero-Ex/KIMODO-Meta3_llm2vec_NF4", local_dir=os.path.join(MODEL_DIR, "Aero-Ex", "KIMODO-Meta3_llm2vec_NF4"), local_dir_use_symlinks=False)

print("\n=== [3/4] Патчинг файлов движка (Офлайн-режим) ===")
# 1. Перезапись обертки (жесткая привязка путей)
wrapper_file = os.path.join(KIMODO_LIB, "model", "llm2vec", "llm2vec_wrapper.py")
wrapper_code = f'''import os
import numpy as np
import torch
from .llm2vec import LLM2Vec

class LLM2VecEncoder:
    def __init__(self, base_model_name_or_path: str, peft_model_name_or_path: str, dtype: str, llm_dim: int, device: str = "auto") -> None:
        torch_dtype = getattr(torch, dtype)
        self.llm_dim = llm_dim
        base_model_name_or_path = r"{text_encoder_path}"
        peft_model_name_or_path = None
        cache_dir = None
        self.model = LLM2Vec.from_pretrained(
            base_model_name_or_path=base_model_name_or_path,
            peft_model_name_or_path=peft_model_name_or_path,
            torch_dtype=torch_dtype,
            cache_dir=cache_dir,
            local_files_only=True
        )
        if device is not None:
            if device == "auto":
                device = "cuda" if torch.cuda.is_available() else "cpu"
            self.model = self.model.to(device)
        self.model.eval()
        for p in self.model.parameters():
            p.requires_grad = False
    def to(self, device: torch.device):
        self.model = self.model.to(device)
        return self
    def eval(self):
        self.model.eval()
        return self
    def get_device(self):
        return self.model.model.device
    def __call__(self, text):
        is_string = False
        if isinstance(text, str):
            text = [text]
            is_string = True
        with torch.no_grad():
            encoded_text = self.model.encode(text, batch_size=1, show_progress_bar=False)
        encoded_text = encoded_text[:, None]
        lengths = np.ones(len(encoded_text), dtype=int).tolist()
        if is_string:
            encoded_text = encoded_text[0]
            lengths = lengths[0]
        encoded_text = torch.tensor(encoded_text).to(self.get_device())
        return encoded_text, lengths
'''
with open(wrapper_file, "w", encoding="utf-8") as f:
    f.write(wrapper_code)

# 2. Фикс загрузчика основной модели
load_file = os.path.join(KIMODO_LIB, "model", "load_model.py")
with open(load_file, "r", encoding="utf-8") as f: lines = f.readlines()
with open(load_file, "w", encoding="utf-8") as f:
    for line in lines:
        if "snapshot_dir = snapshot_download" in line:
            indent = line[:len(line) - len(line.lstrip())]
            f.write(f'{indent}snapshot_dir = r"{main_model_path}"\n')
        else:
            f.write(line)

# 3. Включение офлайн-режима в воркере
for fname in ["kimodo_worker.py", "kimodo_generate.py"]:
    p = os.path.join(KIMODO_LIB, "..", fname)
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8") as f: c = f.read()
        if "HF_HUB_OFFLINE" not in c:
            with open(p, "w", encoding="utf-8") as f:
                f.write('import os\nos.environ["HF_HUB_OFFLINE"]="1"\nos.environ["TRANSFORMERS_OFFLINE"]="1"\n' + c)

print("\n=== [4/4] Настройка DefaultEngine.ini и очистка кэша ===")
model_dir_slash = MODEL_DIR.replace("\\", "/")
ini_file = os.path.join(os.getcwd(), "Config", "DefaultEngine.ini")
if os.path.exists(ini_file):
    with open(ini_file, "r", encoding="utf-8") as f: ini = f.read()
    if "TEXT_ENCODERS_DIR" not in ini:
        with open(ini_file, "a", encoding="utf-8") as f:
            f.write(f'\n[/Script/PythonScriptPlugin.PythonScriptPluginSettings]\n+EnvironmentVariables=(Name="TEXT_ENCODERS_DIR", Value="{model_dir_slash}")\n+EnvironmentVariables=(Name="TEXT_ENCODER", Value="llm2vec-nf4")\n+EnvironmentVariables=(Name="TEXT_ENCODER_MODE", Value="local")\n+EnvironmentVariables=(Name="HF_HUB_OFFLINE", Value="1")\nbInstallDependenciesOnStartup=False\n')
        print("-> DefaultEngine.ini обновлен.")
    else:
        print("-> DefaultEngine.ini уже содержит настройки Kimodo.")

for root, dirs, files in os.walk(KIMODO_LIB):
    for d in dirs:
        if d == "__pycache__":
            shutil.rmtree(os.path.join(root, d), ignore_errors=True)
print("-> Кэш Python очищен.")

print("\n=======================================================")
print("УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!")
print("Теперь ПОЛНОСТЬЮ закройте Unreal Engine и откройте проект снова.")
print("=======================================================")
'@; Set-Content -Path '%TEMP_PY%' -Value $py -Encoding UTF8"

echo [INFO] Установка запущена. Это может занять от 5 до 15 минут...
echo.

"%PYTHON_EXE%" "%TEMP_PY%"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Произошла ошибка во время установки. Проверьте лог выше.
)

del "%TEMP_PY%"
echo.
pause