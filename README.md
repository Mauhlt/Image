# Image Loader

## Purpose
Image library created in zig to read/write different image file types.
This library will read/write data but not visualize the data for you. 
NEED TO SUPPLY YOUR OWN RENDERER FOR NOW.

## Goals:
1. Create Support For:
    - bmp 
    - dib (device independent bmp)
    - jpg/jpeg/JPEG 
    - png 
    - paint 
    - svg 
    - webp 
    - qoi
    - tga (targa)
    - exr
    - dds (direct draw surface)
    - dxt
    - ktx2
    - img
2. Read Image Formats:
    - bmp/dib  
3. Write Image Formats
    - bmp/dib
4. Convert between formats
    - img = default img that can abstract data between types
    - have default values for each image type
    - modifiable values for each image type
5. Benchmark images
    - file size 
        - smaller = more compressed = better
        - high priority
        - sigmoidally weight (small improvements don't matter as much as larger changes)
    - ready time
        - time to load image, uncompress image, send to pipeline
        - medium priority
        - ranked linear weight
    - quality to raw (similarity to raw image)
    - quality to human vision (ability to for humans to perceive differences)
    - throughput
        - 1 / ready time
        - highest priority
        - parallelizable streams
6. Display Images and Come To Personal Conclusion about which image format to use 

## Parsing BMP:
1. BMP Header 
2. DIB Header 
3. Parse Data
4. Apply Filters 

## Parsing PNG: 
1. Intro 
2. Parse PNG structure
3. Parse PNG header
4. Find data 
5. Visualize data 
6. Apply Filters 
7. Extract Color Palette 
