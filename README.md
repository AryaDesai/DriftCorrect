# How to install for windows (temporary)
### Create a conda environment by pasting the below command into Anaconda Promp
conda create -y -n driftcorrect python=3.11
conda activate driftcorrect
### Go to the folder you want to install this package in and then download and unpack the code from github
curl -L -o DriftCorrect.zip https://github.com/AryaDesai/DriftCorrect/archive/refs/heads/main.zip
tar -xf DriftCorrect.zip

### Make a directory called DriftCorrect to store the code
move DriftCorrect-main\DriftCorrectPy_windows DriftCorrect && rmdir /s /q DriftCorrect-main && del DriftCorrect.zip
cd DriftCorrect

### Install the required packages
pip install -r requirements.txt

### Now we want to enable GPU acceleration, check the version for that
nvidia-smi
 #### look for CUDA Version: XX.X
### Install cupy to match that version
pip install "cupy-cuda12x[ctk]"

### Check if it worked:
python -c "from backend import get_backend; print(get_backend().name)"
python drift_correct.py



