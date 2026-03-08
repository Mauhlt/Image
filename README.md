# Image Loader

## Goals:
1. Create a image library
2. Load image formats:
    - jpg 
    - png 
    - bmp 
    - dib 
    - paint 
    - svg 
    - webp 
    - qoi
    - tga = targa
    - exr
    - dds = direct draw surface
    - dxt
3. Write image formats
4. Convert between formats
5. Benchmark images
    - file size 
    - time to load 
    - quality
6. Default to library with the best combined metrics:
    - ready time = time it takes an image to be loaded, uncompressed, ready to send to pipeline
        - 10 ms vs 20 ms, choose 10 ms
        - medium priority
    - memory usage = compressed vs uncompressed 
        - compressed = better ready time = choose that (10 ms vs 20 ms, choose 10 ms)
        - uncompressed = smaller footprint = choose that (rgb vs rgba, choose rgb)
        - lowest priority
    - highest throughput = best = file size / ready time
        - 100 vs 10, choose 100
        - highest priority

## Parsing PNG: 
1. Intro 
2. Parse PNG structure
3. Parse PNG header
4. Find data 
5. Visualize data 
6. Apply Filters 
7. Extract Color Palette 
8. Construct API

## How to use with another program:

## Types of Projections:
1. perspective projection
2. orthographic/rectilinear projection
3. fisheye projection
    - equisolid projection
    - stereo projection
4. cylindrical projection
5. spherical projection
6. equirectangular projection
7. omnimax projection
8. pinhole camera projection
9. panini projection
oo. Links: https://www.youtube.com/watch?v=LE9kxUQ-l14

