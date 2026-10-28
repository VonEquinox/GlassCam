"""Small, bounded local-transform denoising experiment for the F5 image prior.

No model weights, patch search, or additional frames are used. This diagnostic
does not assume the nonlinear reconstruction has independent RGB noise; its
noise-scale approximation must be verified before any product integration.
"""
import numpy as np
from scipy.fft import dctn, idctn

OPPONENT=np.array([[1,1,1],[1,0,-1],[1,-2,1]],float)/np.sqrt([[3],[2],[6]])


def denoise(image, variance, patch=8, stride=2, threshold=2.7, opponent_variance=None, noise_spectrum=None):
    image=np.asarray(image,float);variance=np.broadcast_to(variance,image.shape)
    transformed=image@OPPONENT.T
    transformed_variance=variance@(OPPONENT*OPPONENT).T if opponent_variance is None else np.broadcast_to(opponent_variance,image.shape)
    pad=patch
    values=np.pad(transformed,((pad,pad),(pad,pad),(0,0)),mode='reflect')
    noise=np.pad(transformed_variance,((pad,pad),(pad,pad),(0,0)),mode='reflect')
    output=np.zeros_like(values);mass=np.zeros(values.shape[:2])
    # Fixed overlap, finite support, and exact inverse orthogonal transforms.
    # The unthresholded DC preserves each patch's average radiometry.
    for y in range(0,values.shape[0]-patch+1,stride):
        for x in range(0,values.shape[1]-patch+1,stride):
            block=values[y:y+patch,x:x+patch]
            spectrum=dctn(block,axes=(0,1),norm='ortho')
            sigma=np.sqrt(noise[y:y+patch,x:x+patch].mean(axis=(0,1))*(1 if noise_spectrum is None else noise_spectrum))
            keep=abs(spectrum)>=threshold*sigma
            keep[0,0]=True
            restored=idctn(spectrum*keep,axes=(0,1),norm='ortho')
            output[y:y+patch,x:x+patch]+=restored
            mass[y:y+patch,x:x+patch]+=1
    if np.any(mass[pad:-pad,pad:-pad]<=0):raise ValueError('Uncovered DCT output')
    return (output[pad:-pad,pad:-pad]/mass[pad:-pad,pad:-pad,None])@OPPONENT


def native_from_bilinear(image):
    h,w=image.shape[:2]
    def inverse(n):
        matrix=np.zeros((n,n//2))
        for i in range(n):
            x=np.clip((i+.5)/2-.5,0,n//2-1);j=int(x);a=x-j
            matrix[i,j]+=1-a;matrix[i,min(j+1,n//2-1)]+=a
        return np.linalg.pinv(matrix)
    left,right=inverse(h),inverse(w)
    return np.stack([left@image[:,:,c]@right.T for c in range(3)],axis=-1)
