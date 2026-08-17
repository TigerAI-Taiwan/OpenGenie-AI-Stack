import requests
import time
import json
import sys
import os

def load_env():
    env_vars = {}
    paths = ['./tiger-tuning.env', '../tiger-tuning.env', '../../tiger-tuning.env']
    for path in paths:
        if os.path.exists(path):
            with open(path, 'r') as f:
                for line in f:
                    if '=' in line and not line.startswith('#'):
                        try:
                            k, v = line.strip().split('=', 1)
                            env_vars[k] = v
                        except ValueError:
                            continue
            break
    return env_vars

def get_models(base_url):
    try:
        response = requests.get(f"{base_url}/api/tags")
        if response.status_code == 200:
            return [m['name'] for m in response.json().get('models', [])]
        return []
    except:
        return []

def run_benchmark(base_url, model, prompt):
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": 256
        }
    }
    
    print(f"--- 正在測試模型: {model} ---")
    try:
        start_wall = time.time()
        response = requests.post(f"{base_url}/api/generate", json=payload, timeout=120)
        end_wall = time.time()
        
        if response.status_code != 200:
            print(f"Error: API returned status {response.status_code}")
            return None

        data = response.json()
        eval_count = data.get("eval_count", 0)
        eval_duration = data.get("eval_duration", 1)
        load_duration = data.get("load_duration", 0) / 1_000_000_000
        
        tps = (eval_count / eval_duration) * 1_000_000_000
        total_time = (eval_duration / 1_000_000_000)
        
        return {
            "model": model,
            "tps": round(tps, 2),
            "tokens": eval_count,
            "gen_time": round(total_time, 2),
            "load_time": round(load_duration, 2),
            "wall_time": round(end_wall - start_wall, 2)
        }
    except Exception as e:
        print(f"Error during benchmark: {str(e)}")
        return None

def main():
    env = load_env()
    port = env.get("OLLAMA_PORT", "11434")
    base_url = f"http://localhost:{port}"
    
    models = get_models(base_url)
    if not models:
        print("Error: No models found. Please run 'ollama pull llama3' first.")
        sys.exit(1)
        
    target_model = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else models[0]
    
    prompt = "Explain the concept of quantum entanglement in 200 words."
    
    print("Warm-up run...")
    run_benchmark(base_url, target_model, "Hi")
    
    results = run_benchmark(base_url, target_model, prompt)
    
    if results:
        report = []
        report.append("\n" + "="*40)
        report.append("🚀 TigerAI TPS Performance Report")
        report.append("="*40)
        report.append(f"Model: {results['model']}")
        report.append(f"Speed: {results['tps']} tokens/sec")
        report.append(f"Tokens: {results['tokens']}")
        report.append(f"Inference Time: {results['gen_time']} s")
        report.append(f"Load Time: {results['load_time']} s")
        report.append(f"Total Wall Time: {results['wall_time']} s")
        report.append("="*40)
        print("\n".join(report))

if __name__ == "__main__":
    main()
