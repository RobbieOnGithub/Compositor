#include "ContentFill.h"
#include <stdlib.h>
#include <string.h>
#include <float.h>
#include <limits.h>

static uint32_t next_random(uint32_t *state) {
    *state = *state * 1664525u + 1013904223u;
    return *state;
}
static double match(const uint8_t *pixels, size_t stride, const uint8_t *known,
                    int w, int h, int p, int q, int radius) {
    int px=p%w, py=p/w, qx=q%w, qy=q/w, count=0;
    double sum=0;
    for(int dy=-radius; dy<=radius; ++dy) for(int dx=-radius; dx<=radius; ++dx) {
        int x=px+dx,y=py+dy,sx=qx+dx,sy=qy+dy;
        if(x<0||y<0||x>=w||y>=h||sx<0||sy<0||sx>=w||sy>=h||!known[y*w+x]) continue;
        const uint8_t *a=pixels+y*stride+x*4, *b=pixels+sy*stride+sx*4;
        for(int c=0;c<4;++c) { int d=a[c]-b[c]; sum+=d*d; }
        ++count;
    }
    return count ? sum/count : DBL_MAX;
}
int content_fill(uint8_t *pixels, size_t stride, const uint8_t *mask, size_t ms, int w, int h) {
    // This routine uses signed pixel indexes. Reject before allocation or reading inputs.
    if (!pixels || !mask || w <= 0 || h <= 0 || w > 30000 || h > 30000 ||
        (size_t)w > 100000000u / (size_t)h || stride < (size_t)w * 4 || ms < (size_t)w ||
        stride > SIZE_MAX / (size_t)h || ms > SIZE_MAX / (size_t)h) return -1;
    size_t n=(size_t)w*h;
    uint8_t *known=calloc(n,1), *target=calloc(n,1), *valid=calloc(n,1), *queued=calloc(n,1);
    int *donors=malloc(n*sizeof(int)), *queue=malloc(n*sizeof(int)), *chosen=malloc(n*sizeof(int));
    if(!known||!target||!valid||!queued||!donors||!queue||!chosen) {
        free(known);free(target);free(valid);free(queued);free(donors);free(queue);free(chosen);return -1;
    }
    int radius=(w>=5 && h>=5)?2:0;
    size_t missing=0, donorCount=0, head=0,tail=0, scan=0;
    // Selected pixels are filled. Unselected opaque pixels are the image to match and copy from; unselected
    // transparent ones are neither — nothing to match against, and left as they are.
    for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        int p=y*w+x; target[p]=mask[y*ms+x]!=0; known[p]=!target[p] && pixels[y*stride+x*4+3]==255; chosen[p]=-1;
        if(target[p]) ++missing;
    }
    if(!missing) { donorCount=1; goto done; }
    for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        int p=y*w+x;
        if(!known[p]) continue;
        int ok=1;
        for(int dy=-radius;dy<=radius&&ok;++dy) for(int dx=-radius;dx<=radius;++dx) {
            int sx=x+dx,sy=y+dy;
            if(sx<0||sy<0||sx>=w||sy>=h||!known[sy*w+sx]) {ok=0;break;}
        }
        if(ok) { valid[p]=1;donors[donorCount++]=p; }
    }
    if(!donorCount) goto done;
    for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        int p=y*w+x;
        if(target[p] && ((x&&known[p-1])||(x+1<w&&known[p+1])||(y&&known[p-w])||(y+1<h&&known[p+w]))) {
            queue[tail++]=p;queued[p]=1;
        }
    }
    uint32_t seed=0x6d2b79f5;
    for(;;) {
    while(head<tail) {
        int p=queue[head++],x=p%w,y=p/w,best=-1;
        double score=DBL_MAX;
        int neighbors[4]={x?p-1:-1,x+1<w?p+1:-1,y?p-w:-1,y+1<h?p+w:-1};
        // Propagate coherent source offsets, then refine with randomized patch search.
        for(int k=0;k<28;++k) {
            int q=-1;
            if(k<4) {
                int t=neighbors[k];
                if(t>=0) {
                    int64_t candidate=(int64_t)(chosen[t]>=0?chosen[t]:t)+(int64_t)p-t;
                    if(candidate>=0 && candidate<(int64_t)n) q=(int)candidate;
                }
            } else q=donors[next_random(&seed)%donorCount];
            if(q<0||(size_t)q>=n||!valid[q]) continue;
            double s=match(pixels,stride,known,w,h,p,q,radius);
            if(best<0||s<score) {score=s;best=q;}
        }
        if(best<0) best=donors[0];
        for(int r=64;r>=1;r/=2) {
            int qx=best%w+(int)(next_random(&seed)%(2*r+1))-r;
            int qy=best/w+(int)(next_random(&seed)%(2*r+1))-r;
            if(qx<0||qy<0||qx>=w||qy>=h||!valid[qy*w+qx]) continue;
            int q=qy*w+qx; double s=match(pixels,stride,known,w,h,p,q,radius);
            if(s<score) {score=s;best=q;}
        }
        memcpy(pixels+y*stride+x*4,pixels+(best/w)*stride+(best%w)*4,4);
        known[p]=1;chosen[p]=best;
        for(int k=0;k<4;++k) { int q=neighbors[k]; if(q>=0&&target[q]&&!known[q]&&!queued[q]) {queued[q]=1;queue[tail++]=q;} }
    }
    // A selected area that only transparency touches starts from the best random donor, then spreads.
    while(scan<n && (!target[scan]||known[scan])) ++scan;
    if(scan>=n) break;
    queue[tail++]=(int)scan; queued[scan]=1;
    }
done:
    free(known);free(target);free(valid);free(queued);free(donors);free(queue);free(chosen);
    return donorCount ? 1 : 0;
}
