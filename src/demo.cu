
//=========================================================
// Title:	LOGAN's Demo
// Authors:	A.Zeni, G. Guidi
//=========================================================

#include "logan.cuh"

using namespace std;

#define BATCH_SIZE 30000
#define GPU_THREADS 128

/* nucleotide complement */
char basecomplement(char n) {
  switch (n) {
    case 'A':
      return 'T';
    case 'T':
      return 'A';
    case 'G':
      return 'C';
    case 'C':
      return 'G';
  }
  assert(false);
  return ' ';
}

std::vector<std::string> split(const std::string& s, char delim) {
  std::vector<std::string> result;
  std::stringstream ss(s);
  std::string item;

  while (std::getline(ss, item, delim))
    result.push_back(item);

  return result;
}

/* LOGAN's function call */
void LOGAN(std::vector<std::vector<std::string>>& alignments, int ksize,
           int xdrop, int AlignmentsToBePerformed, int ngpus, int maxt, double& devicet, double& device_total) {
  std::vector<int> posV(AlignmentsToBePerformed);
  std::vector<int> posH(AlignmentsToBePerformed);
  std::vector<SeedL> seeds(AlignmentsToBePerformed);
  std::vector<std::string> seqsV(AlignmentsToBePerformed);
  std::vector<std::string> seqsH(AlignmentsToBePerformed);
  std::vector<ScoringSchemeL> penalties(AlignmentsToBePerformed);
  ScoringSchemeL sscheme(1, -1, -1, -1);

  /* Pre-processing */
  for (int i = 0; i < AlignmentsToBePerformed; i++) {
    posV[i] = std::stoi(alignments[i][1]);
    posH[i] = std::stoi(alignments[i][3]);
    seqsV[i] = alignments[i][0];
    seqsH[i] = alignments[i][2];
    std::string strand = alignments[i][4];

    /* Reverse complement */
    if (strand == "c") {
      std::transform(
          std::begin(seqsH[i]),
          std::end(seqsH[i]),
          std::begin(seqsH[i]),
          basecomplement);
      posH[i] = seqsH[i].length() - posH[i] - ksize;
    }

    /* match, mismatch, gap opening, gap extension */
    penalties[i] = sscheme;
    /* starting position on seqsH, starting position on seqsV, k-mer/seed size */
    SeedL sseed(posH[i], posV[i], ksize);
    seeds[i] = sseed;
  }

  int numAlignmentsLocal = BATCH_SIZE * ngpus;

  //	Divide the alignment in batches of 30K alignments
  for (int i = 0; i < AlignmentsToBePerformed; i += BATCH_SIZE * ngpus) {
    if (AlignmentsToBePerformed < (i + BATCH_SIZE * ngpus))
      numAlignmentsLocal = AlignmentsToBePerformed % (BATCH_SIZE * ngpus);

    int* res = (int*)malloc(numAlignmentsLocal * sizeof(int));

    std::vector<string>::const_iterator first_t = seqsH.begin() + i;
    std::vector<string>::const_iterator last_t = seqsH.begin() + i + numAlignmentsLocal;
    std::vector<string> target_b(first_t, last_t);

    std::vector<string>::const_iterator first_q = seqsV.begin() + i;
    std::vector<string>::const_iterator last_q = seqsV.begin() + i + numAlignmentsLocal;
    std::vector<string> query_b(first_q, last_q);

    std::vector<SeedL>::const_iterator first_s = seeds.begin() + i;
    std::vector<SeedL>::const_iterator last_s = seeds.begin() + i + numAlignmentsLocal;
    std::vector<SeedL> seeds_b(first_s, last_s);

    extendSeedL(seeds_b, EXTEND_BOTHL, target_b, query_b, penalties, xdrop, ksize, res, numAlignmentsLocal, ngpus, GPU_THREADS, devicet, device_total);
    free(res);
  }
}

int main(int argc, char** argv) {
  std::ifstream input(argv[1]);

  int ksize = atoi(argv[2]);
  int xdrop = atoi(argv[3]);
  int ngpus = atoi(argv[4]);

  int maxt = 1;
#pragma omp parallel
  {
    maxt = omp_get_num_threads();
  }

  /* Init the GPU environment */
  cudaFree(0);

  // @AlignmentsToBePerformed = alignments to be performed
  std::cout << "Open file and count newlines:" << std::endl;
//   uint64_t AlignmentsToBePerformedOrig = std::count(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>(), '\n');
  input.seekg(0, std::ios_base::beg);


  auto start = NOW;
  double duration_device = 0.0;
  double duration_device_incl_cpy = 0.0;
  /* Read input file */
  int batchsize = 1'000'000;
  int currentbatch = 0;
  int totalbatch = 0;
  std::cout << "Start loop iteration with batchsize = " << batchsize << std::endl;
  do {
  std::vector<std::string> entries;
  if (input) {
  	std::string line;
  	while (std::getline(input, line) && entries.size() < batchsize) {
  	    entries.push_back(line);
  	}
  }

  currentbatch = entries.size();
  totalbatch += currentbatch;
  std::cout << "laoded " <<  currentbatch << " comparisons" << std::endl;
  std::cout << "total " <<  totalbatch << " comparisons" << std::endl;



  std::vector<std::vector<std::vector<std::string>>> local(maxt);
  std::vector<std::vector<std::string>> alignments(entries.size());

/* Pre-processing */
#pragma omp parallel for
  for (uint64_t i = 0; i < entries.size(); i++) {
    int tid = omp_get_thread_num();
    std::vector<std::string> tmp = split(entries[i], '\t');
    local[tid].push_back(tmp);
  }

  unsigned int alignmentssofar = 0;
  for (int tid = 0; tid < maxt; ++tid) {
    copy(local[tid].begin(), local[tid].end(), alignments.begin() + alignmentssofar);
    alignmentssofar += local[tid].size();
  }

  /* Compute pairwise alignments */
  LOGAN(alignments, ksize, xdrop, entries.size(), ngpus, maxt, duration_device, duration_device_incl_cpy); 
  } while (batchsize == currentbatch);

  auto end = NOW;
  std::chrono::duration<double> tot_time = end - start;
  double duration_tot = tot_time.count();

  input.close();
  std::cout << "Device execution time (with data transfer):\t" << duration_device_incl_cpy << std::endl;
  std::cout << "Device execution time (no data transfer):\t" << duration_device << std::endl;
  std::cout << "Device + host execution time:\t" << duration_tot << std::endl;
  return 0;
}
