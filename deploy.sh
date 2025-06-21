#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    echo "使用方法:"
    echo "  $0 [オプション]"
    echo ""
    echo "オプション:"
    echo "  --full            完全デプロイ（デフォルト）"
    echo "  --lambda-only     Lambda関数のみ更新"
    echo "  --clean           既存リソースをクリーンアップ"
    echo "  --help            このヘルプを表示"
}

FUNCTION_NAME="comment-analyzer"
LAYER_NAME="comment-analyzer-layer"
REGION="ap-northeast-1"
API_NAME="comment-analyzer-api"
BUCKET_NAME="comment-analyzer-web-fixed"
JOB_BUCKET="comment-analyzer-jobs"  

DEPLOY_FULL=true
DEPLOY_LAMBDA=false
CLEAN_RESOURCES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            DEPLOY_FULL=true
            shift
            ;;
        --lambda-only)
            DEPLOY_FULL=false
            DEPLOY_LAMBDA=true
            shift
            ;;
        --clean)
            CLEAN_RESOURCES=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            log_error "不明なオプション: $1"
            show_usage
            exit 1
            ;;
    esac
done

check_aws_config() {
    log_info "AWS設定を確認中..."
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS CLIが設定されていません。aws configureを実行してください。"
        exit 1
    fi
    log_success "AWS設定確認完了"
}

wait_for_function_update() {
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local state=$(aws lambda get-function --function-name $FUNCTION_NAME --region $REGION --query 'Configuration.State' --output text 2>/dev/null || echo "NotFound")
        
        if [ "$state" = "Active" ] || [ "$state" = "NotFound" ]; then
            return 0
        elif [ "$state" = "Pending" ]; then
            log_info "Lambda関数の更新完了を待機中... (${attempt}/${max_attempts})"
            sleep 10
            attempt=$((attempt + 1))
        else
            log_warning "予期しない状態: $state"
            return 1
        fi
    done
    
    log_error "Lambda関数の更新がタイムアウトしました"
    return 1
}

clean_resources() {
    log_info "既存リソースをクリーンアップ中..."
    
    aws lambda remove-permission --function-name $FUNCTION_NAME --statement-id FunctionURLAllowPublicAccess --region $REGION 2>/dev/null || true
    
    aws lambda delete-function-url-config --function-name $FUNCTION_NAME --region $REGION 2>/dev/null || true
    log_success "Lambda Function URL削除完了"
    
    EXISTING_VERSIONS=$(aws lambda list-layer-versions --layer-name $LAYER_NAME --region $REGION --query 'LayerVersions[].Version' --output text 2>/dev/null || echo "")
    if [ ! -z "$EXISTING_VERSIONS" ]; then
        for version in $EXISTING_VERSIONS; do
            log_info "既存のLayerバージョン $version を削除中..."
            aws lambda delete-layer-version --layer-name $LAYER_NAME --version-number $version --region $REGION 2>/dev/null || true
        done
        log_success "Lambda Layer削除完了"
    fi
    
    log_success "リソースクリーンアップ完了"
}

deploy_lambda() {
    log_info "Lambda関数とLayerをデプロイ中..."
    
    log_info "Lambda Layerを作成中..."
    rm -rf lambda_layer
    mkdir -p lambda_layer/python
    cd lambda_layer
    pip install -r ../lambda_requirements.txt -t python/ --upgrade
    zip -r layer.zip python/
    cd ..
    
    EXISTING_VERSIONS=$(aws lambda list-layer-versions --layer-name $LAYER_NAME --region $REGION --query 'LayerVersions[].Version' --output text 2>/dev/null || echo "")
    if [ ! -z "$EXISTING_VERSIONS" ]; then
        for version in $EXISTING_VERSIONS; do
            log_info "既存のLayerバージョン $version を削除中..."
            aws lambda delete-layer-version --layer-name $LAYER_NAME --version-number $version --region $REGION 2>/dev/null || true
        done
    fi
    
    LAYER_VERSION_ARN=$(aws lambda publish-layer-version \
        --layer-name $LAYER_NAME \
        --zip-file fileb://lambda_layer/layer.zip \
        --compatible-runtimes python3.9 \
        --region $REGION \
        --query 'LayerVersionArn' --output text)
    
    log_success "Lambda Layer作成完了: $LAYER_VERSION_ARN"
    
    log_info "Lambda関数パッケージを作成中..."
    zip -r function.zip comment_analyzer.py lambda_function.py
    
    if aws lambda get-function --function-name $FUNCTION_NAME --region $REGION >/dev/null 2>&1; then
        log_info "既存のLambda関数の更新完了を確認中..."
        wait_for_function_update
        
        log_info "Lambda関数のコードを更新中..."
        aws lambda update-function-code \
            --function-name $FUNCTION_NAME \
            --zip-file fileb://function.zip \
            --region $REGION
        
        wait_for_function_update
        
        log_info "Lambda関数の設定を更新中..."
        aws lambda update-function-configuration \
            --function-name $FUNCTION_NAME \
            --layers $LAYER_VERSION_ARN \
            --timeout 900 \
            --memory-size 2048 \
            --region $REGION
    else
        log_info "新しいLambda関数を作成中..."
        aws lambda create-function \
            --function-name $FUNCTION_NAME \
            --runtime python3.9 \
            --role arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/comment-analyzer-role \
            --handler lambda_function.lambda_handler \
            --zip-file fileb://function.zip \
            --layers $LAYER_VERSION_ARN \
            --timeout 900 \
            --memory-size 2048 \
            --region $REGION
    fi
    
    log_info "Lambda関数の最終更新完了を待機中..."
    wait_for_function_update
    
    log_success "Lambda関数デプロイ完了"
}

deploy_function_url() {
    log_info "Lambda Function URLsを設定中..."
    
    aws lambda delete-function-url-config --function-name $FUNCTION_NAME --region $REGION 2>/dev/null || true
    
    FUNCTION_URL=$(aws lambda create-function-url-config \
        --function-name $FUNCTION_NAME \
        --auth-type NONE \
        --cors '{"AllowCredentials":false,"AllowHeaders":["*"],"AllowMethods":["*"],"AllowOrigins":["*"],"MaxAge":86400}' \
        --region $REGION \
        --query 'FunctionUrl' --output text)
    
    log_success "Lambda Function URL作成完了"
    log_success "Function URL: $FUNCTION_URL"
    
    log_info "Function URLのパブリックアクセス権限を設定中..."
    aws lambda add-permission \
        --function-name $FUNCTION_NAME \
        --statement-id FunctionURLAllowPublicAccess \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type NONE \
        --region $REGION 2>/dev/null || true
    
    log_success "パブリックアクセス権限設定完了"
    
    export API_ENDPOINT="$FUNCTION_URL"
}

deploy_web() {
    log_info "S3ウェブサイトをデプロイ中..."
    
    if aws s3 ls "s3://$BUCKET_NAME" 2>/dev/null; then
        log_info "既存のS3バケットを使用: $BUCKET_NAME"
    else
        log_info "新しいS3バケットを作成中..."
        aws s3 mb s3://$BUCKET_NAME --region $REGION
        aws s3 website s3://$BUCKET_NAME --index-document index.html
        
        aws s3api put-public-access-block --bucket $BUCKET_NAME --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
        
        cat > bucket-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
        }
    ]
}
EOF
        aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file://bucket-policy.json
        rm bucket-policy.json
    fi
    
    if [ ! -z "$API_ENDPOINT" ]; then
        log_info "index.htmlのAPI_ENDPOINTを更新中..."
        cp index.html index_updated.html
        
        sed -i.bak "s|const API_ENDPOINT = 'https://[^']*lambda-url[^']*';|const API_ENDPOINT = '$API_ENDPOINT';|g" index_updated.html
        
        sed -i.bak "s|const API_ENDPOINT = 'https://placeholder[^']*';|const API_ENDPOINT = '$API_ENDPOINT';|g" index_updated.html
        
        sed -i.bak "s|const API_ENDPOINT = 'https://[^']*execute-api[^']*';|const API_ENDPOINT = '$API_ENDPOINT';|g" index_updated.html
        
        if grep -q "$API_ENDPOINT" index_updated.html; then
            log_success "API_ENDPOINT更新成功: $API_ENDPOINT"
        else
            log_warning "API_ENDPOINT更新に失敗しました。手動で確認してください。"
            log_info "現在のAPI_ENDPOINT: $(grep 'const API_ENDPOINT' index_updated.html || echo '見つかりません')"
        fi
        
        CACHE_BUSTER=$(date +%s)
        sed -i.bak "s|const CACHE_BUSTER = [0-9]*;|const CACHE_BUSTER = $CACHE_BUSTER;|g" index_updated.html
        
        aws s3 cp index_updated.html s3://$BUCKET_NAME/index.html --cache-control "no-cache, no-store, must-revalidate"
        rm -f index_updated.html index_updated.html.bak
    else
        log_warning "API_ENDPOINTが設定されていません。元のindex.htmlをアップロードします。"
        aws s3 cp index.html s3://$BUCKET_NAME/index.html --cache-control "no-cache, no-store, must-revalidate"
    fi
    
    log_success "S3ウェブサイトデプロイ完了"
    log_success "ウェブサイトURL: http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"
}

create_job_bucket() {
    log_info "ジョブ管理用S3バケットを作成中..."
    
    if aws s3 ls "s3://$JOB_BUCKET" 2>/dev/null; then
        log_info "既存のジョブ管理バケットを使用: $JOB_BUCKET"
    else
        log_info "新しいジョブ管理バケットを作成中..."
        aws s3 mb s3://$JOB_BUCKET --region $REGION
        
        aws s3api put-bucket-encryption \
            --bucket $JOB_BUCKET \
            --server-side-encryption-configuration '{
                "Rules": [
                    {
                        "ApplyServerSideEncryptionByDefault": {
                            "SSEAlgorithm": "AES256"
                        }
                    }
                ]
            }'
        
        log_success "ジョブ管理バケット作成完了: $JOB_BUCKET"
    fi
}

cleanup_temp_files() {
    log_info "一時ファイルをクリーンアップ中..."
    rm -f function.zip lambda_layer/layer.zip index_updated.html index_updated.html.bak
    rm -rf lambda_layer
    log_success "一時ファイルクリーンアップ完了"
}

main() {
    echo "講義コメント分析システム 統合デプロイスクリプト"
    echo "=================================================="
    
    check_aws_config
    
    if [ "$CLEAN_RESOURCES" = true ]; then
        clean_resources
    fi
    
    if [ "$DEPLOY_FULL" = true ]; then
        deploy_lambda
        deploy_function_url
        deploy_web
        create_job_bucket
    else
        if [ "$DEPLOY_LAMBDA" = true ]; then
            deploy_lambda
        fi
    fi
    
    cleanup_temp_files
    
    echo ""
    echo "デプロイが完了しました！"
    echo "=================================================="
    if [ ! -z "$API_ENDPOINT" ]; then
        echo "API: $API_ENDPOINT"
    fi
    echo "WEB: http://$BUCKET_NAME.s3-website-$REGION.amazonaws.com"
}

main "$@" 