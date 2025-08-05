import logging
from typing import Annotated

from fastapi import APIRouter, Query, HTTPException, Request, Depends
from fastapi.responses import RedirectResponse

from mediaflow_proxy.extractors.base import ExtractorError
from mediaflow_proxy.extractors.factory import ExtractorFactory
from mediaflow_proxy.schemas import ExtractorURLParams
from mediaflow_proxy.utils.cache_utils import get_cached_extractor_result, set_cache_extractor_result
from mediaflow_proxy.utils.http_utils import (
    encode_mediaflow_proxy_url,
    get_original_scheme,
    ProxyRequestHeaders,
    get_proxy_headers,
)

extractor_router = APIRouter()
logger = logging.getLogger(__name__)


def process_destination_url(destination: str, is_base64: bool = False) -> str:
    """
    Process the destination URL, optionally decoding from base64.
    
    Args:
        destination (str): The destination URL.
        is_base64 (bool): Whether the URL is base64 encoded.
        
    Returns:
        str: The processed URL.
    """
    if is_base64:
        import base64
        try:
            # Remove any URL-safe base64 padding if needed
            decoded_bytes = base64.b64decode(destination + '==')  # Add padding to be safe
            decoded_url = decoded_bytes.decode('utf-8')
            logger.info(f"Successfully decoded base64 URL: {destination[:50]}... -> {decoded_url}")
            return decoded_url
        except Exception as e:
            logger.error(f"Failed to decode base64 URL '{destination}': {e}")
            raise HTTPException(status_code=400, detail=f"Invalid base64 URL: {str(e)}")
    
    return destination


@extractor_router.head("/video")
@extractor_router.get("/video")
async def extract_url(
    extractor_params: Annotated[ExtractorURLParams, Query()],
    request: Request,
    proxy_headers: Annotated[ProxyRequestHeaders, Depends(get_proxy_headers)],
):
    """Extract clean links from various video hosting services."""
    try:
        # Process destination URL (decode base64 if needed)
        extractor_params.destination = process_destination_url(extractor_params.destination, extractor_params.b64)
        
        cache_key = f"{extractor_params.host}_{extractor_params.model_dump_json()}"
        response = await get_cached_extractor_result(cache_key)
        if not response:
            extractor = ExtractorFactory.get_extractor(extractor_params.host, proxy_headers.request)
            response = await extractor.extract(extractor_params.destination, **extractor_params.extra_params)
            await set_cache_extractor_result(cache_key, response)
        else:
            response["request_headers"].update(proxy_headers.request)

        response["mediaflow_proxy_url"] = str(
            request.url_for(response.pop("mediaflow_endpoint")).replace(scheme=get_original_scheme(request))
        )
        response["query_params"] = response.get("query_params", {})
        # Add API password to query params
        response["query_params"]["api_password"] = request.query_params.get("api_password")

        if extractor_params.redirect_stream:
            stream_url = encode_mediaflow_proxy_url(
                **response,
                response_headers=proxy_headers.response,
            )
            return RedirectResponse(url=stream_url, status_code=302)

        return response

    except ExtractorError as e:
        logger.error(f"Extraction failed: {str(e)}")
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.exception(f"Extraction failed: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Extraction failed: {str(e)}")
