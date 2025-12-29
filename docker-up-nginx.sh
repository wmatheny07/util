#/bin/bash
source ~/miniconda3/bin/activate

util_path=/opt/util/
env_file_path=/opt/config/.env.prod
service_path=/opt/nginx/
input_file=/opt/nginx/nginx.conf.template
output_file=/opt/nginx/nginx.conf

conda activate py_3.7

python3 "${util_path}env_inject.py" ${input_file} ${output_file}

docker-compose -f "${service_path}docker-compose.nginx.yml" --env-file $env_file_path up --build -d

rm $output_file

exit