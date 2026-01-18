# Projects
1. Liquid Glass Effect 
- PBR
- Physics Engine
- thickness, roughness, transmission, metalness, transparency
- marching cubes
2. Black and White Images
- bulke effect = depth of field
- stencil effect = just lines
3. Mouse Interaction
- interact with objects using mouse
4. Particle With TSL
- add glow
- atomizes objects
5. Graphic Art = Creative Coding Composition
6. Animation + Fireflies Effect
- fbx file
- give value same name as property
7. Fluid Distortion Effect
8. Creative Coding 
- Allow different shapes (cubes, icosphere)
- Allow transparency
- Allow objects behind transparent object to have hinted color
- Allow objects behind transparent objects to have new shadows
9. Meta Cube
- instanced mesh + noise
- update instance color
- Watch color change across shape
10. Add model
- have models coagulate into a shape
11. TSL Rainbow Shader
- TSL = three.js language, can also use glsl
- mesh should cast shadows
- mesh should interact with hand when given video of hand
12. Painting With Decals
- load model
- setup decal
- use raycaster to paint model with decal
13. Post-Processing Effects
- dot screen - converts model to dots
- rgb shift
- pixelization
- after image or trail
- bloom
- outline
14. Convert hand into a controller
- use ai to map hand position
- position those points in virtual space
- give them physics to move objects
- webcam -> mediapipe -> kinematic colliders -> dynamics
- webcam -> video element
- Debug Renderer = Helps you understand what happens in the scene
15. Masking + Rapier Physics
- render scene to render target
- base scene
- mask 
- hidden scene
- take alpha channel for mask, combine main layer with hidden layer
16. AI Agents: A New Workflow
- remove reflections
- use ai to improve designs

Goals:
- stack of blocks = https://www.youtube.com/watch?v=BtJfHoxAc4w
    - all blocks fall down, land on each other, stay stable
- balls fall down chute, over waterwheel, land in bucket
- fire ball at target
- ecs, constraints, and architecture
- ECS:
    - data driven memory layout
    - constraint pipeline
    - collision pipeline
    - force calculators
    - constraint solver
        - translational + rotational
        - ragdoll
    - integrator
- use springs to approx cloth
