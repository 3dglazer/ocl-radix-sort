// OpenCL kernel sources for the CLRadixSort class
// the #include does not exist in OpenCL
// thus we simulate the #include "CLRadixSortParam.hpp" by
// string manipulations

#pragma OPENCL EXTENSION cl_amd_printf : enable

__kernel
void bitonicSortLocal(
    __local int *l_key,
    __local int *l_val
		      );

// compute the histogram for each radix and each virtual processor for the pass
__kernel void histogram(const __global int* d_Keys,
			__global int* d_Histograms,
			const int pass,
			__local int* loc_histo,
			const int n){

  int it = get_local_id(0);  // i local number of the processor
  int ig = get_global_id(0); // global number = i + g I

  int gr = get_group_id(0); // g group number

  int groups=get_num_groups(0);
  int items=get_local_size(0);

  // set the local histograms to zero
  for(int ir=0;ir<_RADIX;ir++){
    loc_histo[ir * items + it] = 0;
  }

  barrier(CLK_LOCAL_MEM_FENCE);  


  // range of keys that are analyzed by the work item
  int size= n/groups/items; // size of the sub-list
  int start= ig * size; // beginning of the sub-list

  int key,shortkey,k;

  // compute the index
  // the computation depends on the transposition
  for(int j= 0; j< size;j++){
#ifdef TRANSPOSE
    k= groups * items * j + ig;
#else
    k=j+start;
#endif
      
    key=d_Keys[k];   

    // extract the group of _BITS bits of the pass
    // the result is in the range 0.._RADIX-1
    shortkey=(( key >> (pass * _BITS)) & (_RADIX-1));  

    // increment the local histogram
    loc_histo[shortkey *  items + it ]++;
  }

  barrier(CLK_LOCAL_MEM_FENCE);  

  // copy the local histogram to the global one
  for(int ir=0;ir<_RADIX;ir++){
    d_Histograms[items * (ir * groups + gr) + it]=loc_histo[ir * items + it];
  }
  
  barrier(CLK_GLOBAL_MEM_FENCE);  


}

// initial transpose of the list for improving
// coalescent memory access
__kernel void transpose(const __global int* invect,
			__global int* outvect,
			const int nbcol,
			const int nbrow,
			const __global int* inperm,
			__global int* outperm,
			__local int* blockmat,
			__local int* blockperm,
			const int tilesize){
  
  int i0 = get_global_id(0)*tilesize;  // first row index
  int j = get_global_id(1);  // column index

  int jloc = get_local_id(1);  // local column index

  // fill the cache
  for(int iloc=0;iloc<tilesize;iloc++){
    int k=(i0+iloc)*nbcol+j;  // position in the matrix
    blockmat[iloc*tilesize+jloc]=invect[k];
#ifdef PERMUT 
    blockperm[iloc*tilesize+jloc]=inperm[k];
#endif
  }

  barrier(CLK_LOCAL_MEM_FENCE);  

  // first row index in the transpose
  int j0=get_group_id(1)*tilesize;

  // put the cache at the good place
  for(int iloc=0;iloc<tilesize;iloc++){
    int kt=(j0+iloc)*nbrow+i0+jloc;  // position in the transpose
    outvect[kt]=blockmat[jloc*tilesize+iloc];
#ifdef PERMUT 
      outperm[kt]=blockperm[jloc*tilesize+iloc];
#endif
  }
 
}

// each virtual processor reorders its data using the scanned histogram
__kernel void reorder(const __global int* d_inKeys,
		      __global int* d_outKeys,
		      __global int* d_Histograms,
		      const int pass,
		      __global int* d_inPermut,
		      __global int* d_outPermut,
		      __local int* loc_histo,
		      const int n){

  int it = get_local_id(0);
  int ig = get_global_id(0);

  int gr = get_group_id(0);
  int groups=get_num_groups(0);
  int items=get_local_size(0);

  int start= ig *(n/groups/items);
  int size= n/groups/items;

  // take the histogram in the cache
  for(int ir=0;ir<_RADIX;ir++){
    loc_histo[ir * items + it]=
      d_Histograms[items * (ir * groups + gr) + it];
  }
  barrier(CLK_LOCAL_MEM_FENCE);  


  int newpos,key,shortkey,k,newpost;

  for(int j= 0; j< size;j++){
#ifdef TRANSPOSE
      k= groups * items * j + ig;
#else
      k=j+start;
#endif
    key = d_inKeys[k];   
    shortkey=((key >> (pass * _BITS)) & (_RADIX-1)); 

    newpos=loc_histo[shortkey * items + it];


#ifdef TRANSPOSE
    int ignew,jnew;
    ignew= newpos/(n/groups/items);
    jnew = newpos%(n/groups/items);
    newpost = jnew * (groups*items) + ignew;
#else
    newpost=newpos;
#endif

    d_outKeys[newpost]= key;  // killing line !!!

#ifdef PERMUT 
      d_outPermut[newpost]=d_inPermut[k]; 
#endif

    newpos++;
    loc_histo[shortkey * items + it]=newpos;

  }  

}

// perform a exclusive parallel prefix sum on an array stored in local
// memory and return the sum in (*sum)
// the size of the array HAS to be twice the  number of work-items +1
// (the last element contains the total sum)
// ToDo: the function could be improved by avoiding bank conflicts...  

void localscan(__local int* temp,int n){

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int decale = 1; 
  //int n=get_local_size(0) * 2 ;
 	
  // parallel prefix sum (algorithm of Blelloch 1990) 
  for (int d = n>>1; d > 0; d >>= 1){   
    barrier(CLK_LOCAL_MEM_FENCE);  
    if (it < d){  
      int ai = decale*(2*it+1)-1;  
      int bi = decale*(2*it+2)-1;  	
      temp[_D(bi)] += temp[_D(ai)];  
    }  
    decale <<= 1; 
    //barrier(CLK_LOCAL_MEM_FENCE);  
  }
  
  // store the last element in the global sum vector
  // (maybe used in the next step for constructing the global scan)
  // clear the last element
  if (it == 0) {
    temp[_D(n)]=temp[_D(n-1)];
    temp[_D(n - 1)] = 0;
  }
                 
  // down sweep phase
  for (int d = 1; d < n; d *= 2){  
    decale >>= 1;  
    barrier(CLK_LOCAL_MEM_FENCE);

    if (it < d){  
      int ai = decale*(2*it+1)-1;  
      int bi = decale*(2*it+2)-1;  
         
      int t = temp[_D(ai)];  
      temp[_D(ai)] = temp[_D(bi)];  
      temp[_D(bi)] += t;   
    }  
    //barrier(CLK_LOCAL_MEM_FENCE);

  }  
  barrier(CLK_LOCAL_MEM_FENCE);
}


// same as before but the size of the vector can of the form
// n = 2^p0 nw with nw = work group size
//  p0=1 in the previous algorithm
void localscan2(__local int* temp,int n){
    barrier(CLK_LOCAL_MEM_FENCE);  

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int nw=get_local_size(0);
  int small = n/nw/2;  // small = 2^(p0-1) =2 si p0=2
  for(int i=1;i<small;i++){
    temp[_D(small*it+i)]+=temp[_D(small*it+i-1)];
    temp[_D(small*it+i+n/2)]+=temp[_D(small*it+i-1+n/2)];
  };
  temp[_D(small*it)]=temp[_D(small*it+small-1)];
  temp[_D(small*it+n/2)]=temp[_D(small*it+small-1+n/2)];



  int decale = small; 
  // parallel prefix sum (algorithm of Blelloch 1990) 
  barrier(CLK_LOCAL_MEM_FENCE);  
  for (int d = nw; d >= 1; d >>= 1){   
    if (it < d){  
      int ai = decale*(2*it+1)-small;  
      int bi = decale*(2*it+2)-small;  	
      temp[_D(bi)] += temp[_D(ai)];  
    }  
    decale <<= 1; 
    //barrier(CLK_LOCAL_MEM_FENCE);  
  barrier(CLK_LOCAL_MEM_FENCE);  
  }



  // store the last element in the global sum vector
  // (maybe used in the next step for constructing the global scan)
  // clear the last element
  if (it == 0) {
    temp[_D(n)]=temp[_D(n-small)];
    temp[_D(n - small)] = 0;
  }
                 

  // down sweep phase
  for (int d = 1; d <= nw; d <<= 1){  
    decale >>= 1;  
    barrier(CLK_LOCAL_MEM_FENCE);

    if (it < d){  
      int ai = decale*(2*it+1)-small;  
      int bi = decale*(2*it+2)-small;  
         
      int t = temp[_D(ai)];  
      temp[_D(ai)] = temp[_D(bi)];  
      temp[_D(bi)] += t;   
    }  
    //barrier(CLK_LOCAL_MEM_FENCE);

  }

  barrier(CLK_LOCAL_MEM_FENCE);  
  printf("resuls=%d\n",it);
  for(int i=0;i<2*small;i++){
    printf("%d,%d\n",2*small*it+i,temp[_D(2*small*it+i)]);
  }  
  barrier(CLK_LOCAL_MEM_FENCE);  


  
  barrier(CLK_LOCAL_MEM_FENCE);
  
  for(int i=small-1;i>0;i--){
    temp[_D(small*it+i)]=temp[_D(small*it+i-1)]+temp[_D(small*it)];
    temp[_D(small*it+i+n/2)]=temp[_D(small*it+i-1+n/2)]+temp[_D(small*it+n/2)];
  };



}


// perform a parallel prefix sum (a scan) on the local histograms
// (see Blelloch 1990) each workitem worries about two memories
// see also http://http.developer.nvidia.com/GPUGems3/gpugems3_ch39.html
__kernel void scanhistograms( __global int* histo,__local int* temp,__global int* globsum){


  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int sum;

  // load a part of the histogram into local memory
  temp[_D(2*it)] = histo[2*ig];  
  temp[_D(2*it+1)] = histo[2*ig+1];  
  barrier(CLK_LOCAL_MEM_FENCE);

  // scan the local vector with
  // the Blelloch's parallel algorithm
  localscan(temp,2*get_local_size(0));

  // remember the sum for the next scanning step
  if (it == 0){
    globsum[gr]=temp[_D(2 * get_local_size(0))];
  }
  // write results to device memory

  histo[2*ig] = temp[_D(2*it)];  
  histo[2*ig+1] = temp[_D(2*it+1)];  

  barrier(CLK_GLOBAL_MEM_FENCE);

}  

// first step of the Satish algorithm: sort local blocks that fit into local
// memory with a radix=2^1 sorting algorithm
// and compute the groups histogram with the big radix=2^_BITS
// we thus need _BITS/1 passes
// let n=blocksize be the size of the local list
// the histogram is then of size 2^1 * n
// because we perform a localscan (see above) 
// it implies that the number of
// work-items nitems satisfies
// 2*nitems =  2 * n or
// nitems = n 
__kernel void sortblock( __global int* keys,   // the keys to be sorted
			 __local int* loc_in,  // a copy of the keys in local memory
			 __local int* loc_out,  // a copy of the keys in local memory
			 __local int* grhisto, // scanned group histogram
			 __global int* histo,   // not yet scanned global histogram
			 __global int* offset,   // offset of the radix of each group
			 const uint gpass)   // # of the pass
{   

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int blocksize=get_local_size(0); // see above
  int sum;
  __local int* temp; // local pointer for memory exchanges

  // load keys into local memory
  loc_in[it] = keys[ig];  

  // sort the local list with a radix=2 sort
  // also called split algorithm
  for(int pass=0;pass < _BITS;pass+=_SMALLBITS){

    // init histogram to zero
    for (int rad=0;rad<_SMALLRADIX;rad++){
      grhisto[_D(rad*blocksize+it)]=0;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    
    // histogram of the pass
    int key,shortkey;
    key=loc_in[it];
    shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));
    shortkey=(( shortkey >> pass  ) & (_SMALLRADIX-1));  // key bit of the pass
    grhisto[_D(shortkey*blocksize+it)]++;     // yes
    //barrier(CLK_LOCAL_MEM_FENCE);
    // grhisto[_D(4*it+0)] = 1;  
    // grhisto[_D(4*it+1)] = 1;  
    // grhisto[_D(4*it+2)] = 1;  
    // grhisto[_D(4*it+3)] = 1;  

    // scan (exclusive) the local vector
    // grhisto is of size blocksize+1
    // the last value is the total sum
    localscan(grhisto,_SMALLRADIX*blocksize);
    
    // reorder in local memory    
    loc_out[grhisto[_D(shortkey*blocksize+it)]] = loc_in[it];
    grhisto[_D(shortkey*blocksize+it)]++;  
    barrier(CLK_LOCAL_MEM_FENCE);

    // exchange old and new keys into local memory
    temp=loc_in;
    loc_in=loc_out;
    loc_out=temp;

  } // end of split pass

  // now compute the histogram of the group
  // using the ordered keys and the already used
  // local memory

  int key1,key2,shortkey1,shortkey2;

  if (it == 0) {
    loc_out[0]=0;
    loc_out[_RADIX]=blocksize;
    shortkey1=0;
  }
  else {
    key1=loc_in[it-1];
    //int gpass=0;
    shortkey1=(( key1 >> (gpass * _BITS) ) & (_RADIX-1));  // key1 radix
  }
   
  key2=loc_in[it];
  shortkey2=(( key2 >> (gpass * _BITS) ) & (_RADIX-1));  // key2 radix
    
  for(int rad=shortkey1;rad<shortkey2;rad++){
    loc_out[rad+1]=it;
  }
  
  barrier(CLK_LOCAL_MEM_FENCE);

  // compute the local histogram
  if (it < _RADIX) {
    grhisto[it]=loc_out[it+1]-loc_out[it];
  }
  //barrier(CLK_LOCAL_MEM_FENCE);
  
  // put the results into global memory

  int key=loc_in[it];
  //int gpass=0;
  int shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));  // key radix
  
  // the keys
  keys[ig]=loc_in[it];

  // store the histograms and the offset
  if (it < _RADIX) {
    histo[it *(_N/_BLOCKSIZE)+gr]=grhisto[it]; // not coalesced !
    offset[gr *_RADIX + it]=loc_out[it]; // coalesced 
  }
  //barrier(CLK_GLOBAL_MEM_FENCE);
}  


// same as before but with two keys/work-item and a local bitonic sort
// because the bitonic sort is not stable it works only when
// _BITS == _TOTALBITS :-(
__kernel void sortblock2( __global int* keys,   // the keys to be sorted
			 __local int* loc_in,  // a copy of the keys in local memory
			 __local int* loc_out,  // a copy of the keys in local memory
			 __local int* grhisto, // scanned group histogram
			 __global int* histo,   // not yet scanned global histogram
			 __global int* offset,   // offset of the radix of each group
			 const uint gpass)   // # of the pass
{   

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int blocksize=2*get_local_size(0); // see above
  int sum;
  __local int* temp; // local pointer for memory exchanges

  // load keys into local memory
  loc_in[2*it] = keys[2*ig];  
  loc_in[2*it+1] = keys[2*ig+1];  
  barrier(CLK_LOCAL_MEM_FENCE);

  // sort the local list with a bitonic local sort
  bitonicSortLocal(loc_in,loc_out);

  // now compute the histogram of the group
  // using the ordered keys and the already used
  // local memory

  int key1,key2,shortkey1,shortkey2;

  if (it == 0) {
    loc_out[_RADIX]=blocksize;
    loc_out[0]=0;
    shortkey1=0;
  }
  else{
    key1=loc_in[2*it-1];
    shortkey1=(( key1 >> (gpass * _BITS) ) & (_RADIX-1));  // key1 radix
  }
  key2=loc_in[2*it];
  shortkey2=(( key2 >> (gpass * _BITS) ) & (_RADIX-1));  // key2 radix    
  for(int rad=shortkey1;rad<shortkey2;rad++){
    loc_out[rad+1]=2*it;
  }
  key1=loc_in[2*it];
  shortkey1=(( key1 >> (gpass * _BITS) ) & (_RADIX-1));  // key1 radix
  key2=loc_in[2*it+1];
  shortkey2=(( key2 >> (gpass * _BITS) ) & (_RADIX-1));  // key2 radix    
  for(int rad=shortkey1;rad<shortkey2;rad++){
    loc_out[rad+1]=2*it+1;
  }
  
  barrier(CLK_LOCAL_MEM_FENCE);

  // compute the local histogram
  if (it < _RADIX/2) {
    grhisto[2*it]=loc_out[2*it+1]-loc_out[2*it];
    grhisto[2*it+1]=loc_out[2*it+2]-loc_out[2*it+1];
  }
  //barrier(CLK_LOCAL_MEM_FENCE);
  
  // put the results into global memory

  int key=loc_in[2*it];
  //int gpass=0;
  //int shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));  // key radix  
  // the keys
  keys[2*ig]=loc_in[2*it];
  key=loc_in[2*it+1];
  //int gpass=0;
  //shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));  // key radix  
  // the keys
  keys[2*ig+1]=loc_in[2*it+1];

  // store the histograms and the offset
  if (it < _RADIX/2) {
    histo[2*it *(_N/_BLOCKSIZE)+gr]=grhisto[2*it]; // not coalesced !
    offset[gr *_RADIX + 2*it]=loc_out[2*it]; // coalesced 
    histo[(2*it+1) *(_N/_BLOCKSIZE)+gr]=grhisto[2*it+1]; // not coalesced !
    offset[gr *_RADIX + 2*it+1]=loc_out[2*it+1]; // coalesced 
  }
  barrier(CLK_GLOBAL_MEM_FENCE);
}  

// reorder step of the Satish algorithm
// use the scanned histogram and the block offsets to reorder
// the locally reordered keys
// many memeory access are coalesced because of the initial ordering
__kernel void reordersatish( const __global int* inkeys,   // the keys to be sorted
			     __global int* outkeys,  //  the sorted keys 
			     __local int* locoffset,  // a copy of the offset in local memory
			     __local int* grhisto, // scanned group histogram
			     const __global int* histo,   //  global scanned histogram
			     const __global int* offset,   // offset of the radix of each group
			     const uint gpass)   // # of the pass
{

  int it = get_local_id(0);
  int ig = get_global_id(0);
  int gr=get_group_id(0);
  int blocksize=get_local_size(0);
  
  // store locally the histograms and the offset
  if (it < _RADIX) {
    grhisto[it]=histo[it *(_N/_BLOCKSIZE)+gr]; // not coalesced !
    locoffset[it]=offset[gr *_RADIX + it]; // coalesced 
  }
  barrier(CLK_LOCAL_MEM_FENCE);

  int key = inkeys[ig];  

  int shortkey=(( key >> (gpass * _BITS) ) & (_RADIX-1));  // key radix

  // move the key at the good place, using
  // the scanned histogram and the offset
  outkeys[grhisto[shortkey]+it-locoffset[shortkey]]=key;

  barrier(CLK_GLOBAL_MEM_FENCE);
}  


// use the global sum for updating the local histograms
// each work item updates two values
__kernel void pastehistograms( __global int* histo,const __global int* globsum){


  int ig = get_global_id(0);
  int gr=get_group_id(0);

  int s;

  s=globsum[gr];
  
  // write results to device memory
  histo[2*ig] += s;  
  histo[2*ig+1] += s;  

  barrier(CLK_GLOBAL_MEM_FENCE);

}  

//Passed down by clBuildProgram
#define LOCAL_SIZE_LIMIT _BLOCKSIZE



// inline void ComparatorPrivate(
//     uint *keyA,
//     uint *valA,
//     uint *keyB,
//     uint *valB,
//     uint arrowDir
// ){
//     if( (*keyA > *keyB) == arrowDir ){
//         uint t;
//         t = *keyA; *keyA = *keyB; *keyB = t;
//         t = *valA; *valA = *valB; *valB = t;
//     }
// }

inline void ComparatorLocal(
    __local uint *keyA,
    __local uint *valA,
    __local uint *keyB,
    __local uint *valB,
    uint arrowDir
){
    if( (*keyA > *keyB) == arrowDir ){
        uint t;
        t = *keyA; *keyA = *keyB; *keyB = t;
        t = *valA; *valA = *valB; *valB = t;
    }
}

////////////////////////////////////////////////////////////////////////////////
// Monolithic bitonic sort kernel for short arrays fitting into local memory
////////////////////////////////////////////////////////////////////////////////
//__kernel __attribute__((reqd_work_group_size(LOCAL_SIZE_LIMIT / 2, 1, 1)))
void bitonicSortLocal(
    __local int *l_key,
    __local int *l_val
){
// void bitonicSortLocal(
//     __global int *d_DstKey,
//     __global int *d_DstVal,
//     __global int *d_SrcKey,
//     __global int *d_SrcVal,
//     int arrayLength,
//     int sortDir
// ){
    // __local  int l_key[LOCAL_SIZE_LIMIT];
    // __local  int l_val[LOCAL_SIZE_LIMIT];

    // //Offset to the beginning of subbatch and load data
    // d_SrcKey += get_group_id(0) * LOCAL_SIZE_LIMIT + get_local_id(0);
    // d_SrcVal += get_group_id(0) * LOCAL_SIZE_LIMIT + get_local_id(0);
    // d_DstKey += get_group_id(0) * LOCAL_SIZE_LIMIT + get_local_id(0);
    // d_DstVal += get_group_id(0) * LOCAL_SIZE_LIMIT + get_local_id(0);
    // l_key[get_local_id(0) +                      0] = d_SrcKey[                     0];
    // l_val[get_local_id(0) +                      0] = d_SrcVal[                     0];
    // l_key[get_local_id(0) + (LOCAL_SIZE_LIMIT / 2)] = d_SrcKey[(LOCAL_SIZE_LIMIT / 2)];
    // l_val[get_local_id(0) + (LOCAL_SIZE_LIMIT / 2)] = d_SrcVal[(LOCAL_SIZE_LIMIT / 2)];

  int arrayLength = LOCAL_SIZE_LIMIT;
  int sortDir=1;  // increasing sort

    for(int size = 2; size < arrayLength; size <<= 1){
        //Bitonic merge
        int dir = ( (get_local_id(0) & (size / 2)) != 0 );
        for(int stride = size / 2; stride > 0; stride >>= 1){
            barrier(CLK_LOCAL_MEM_FENCE);
            int pos = 2 * get_local_id(0) - (get_local_id(0) & (stride - 1));
            ComparatorLocal(
                &l_key[pos +      0], &l_val[pos +      0],
                &l_key[pos + stride], &l_val[pos + stride],
                dir
            );
        }
    }

    //dir == sortDir for the last bitonic merge step
    {
        for(int stride = arrayLength / 2; stride > 0; stride >>= 1){
            barrier(CLK_LOCAL_MEM_FENCE);
            int pos = 2 * get_local_id(0) - (get_local_id(0) & (stride - 1));
            ComparatorLocal(
                &l_key[pos +      0], &l_val[pos +      0],
                &l_key[pos + stride], &l_val[pos + stride],
                sortDir
            );
        }
    }

     barrier(CLK_LOCAL_MEM_FENCE);
    // d_DstKey[                     0] = l_key[get_local_id(0) +                      0];
    // d_DstVal[                     0] = l_val[get_local_id(0) +                      0];
    // d_DstKey[(LOCAL_SIZE_LIMIT / 2)] = l_key[get_local_id(0) + (LOCAL_SIZE_LIMIT / 2)];
    // d_DstVal[(LOCAL_SIZE_LIMIT / 2)] = l_val[get_local_id(0) + (LOCAL_SIZE_LIMIT / 2)];
}



