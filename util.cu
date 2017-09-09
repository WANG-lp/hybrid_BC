#include "util.cuh"
#include <queue>

//Note: Times are returned in seconds
void start_clock(cudaEvent_t &start, cudaEvent_t &end)
{
	checkCudaErrors(cudaEventCreate(&start));
	checkCudaErrors(cudaEventCreate(&end));
	checkCudaErrors(cudaEventRecord(start,0));
}

float end_clock(cudaEvent_t &start, cudaEvent_t &end)
{
	float time;
	checkCudaErrors(cudaEventRecord(end,0));
	checkCudaErrors(cudaEventSynchronize(end));
	checkCudaErrors(cudaEventElapsedTime(&time,start,end));
	checkCudaErrors(cudaEventDestroy(start));
	checkCudaErrors(cudaEventDestroy(end));

	return time/(float)1000;
}

program_options parse_arguments(int argc, char *argv[])
{
	program_options op;
	int c;

	static struct option long_options[] =
	{
		{"device",required_argument,0,'d'},
		{"help",no_argument,0,'h'},
		{"infile",required_argument,0,'i'},
		{"approx",required_argument,0,'k'},
		{"printscores",optional_argument,0,'p'},
		{"verify",no_argument,0,'v'},
		{0,0,0,0} //Terminate with null
	};

	int option_index = 0;

	while((c = getopt_long(argc,argv,"d:hi:k:p::v::r",long_options,&option_index)) != -1)
	{
		switch(c)
		{
			case 'd':
				op.device = atoi(optarg);
			break;

			case 'h':
				std::cout << "Usage: " << argv[0] << " -i <input graph file> [-v verify GPU calculation] [-p <output file> print BC scores] [-d <device ID> choose GPU (starting from 0)]" << std::endl;	
			exit(0);

			case 'i':
				op.infile = optarg;
			break;

			case 'k':{
				op.approx = true;
				int r = 0;
                for(int i = 0; i < strlen(optarg) -1; i++){
                    r = r * 10 + (optarg[i] - '0');
                }
                op.ratio = r / 100.0;
                std::cout << "ratio: " << op.ratio<<std::endl;
            }
			break;

			case 'p':
				op.printBCscores = true;
				op.scorefile = optarg;
			break;

			case 'v':
				op.verify = true;
			break;
            case 'r':
                op.one_deg_reduce = true;
                break;
			
			case '?': //Invalid argument: getopt will print the error msg itself
				
			exit(-1);

			default: //Fatal error
				std::cerr << "Fatal error parsing command line arguments. Terminating." << std::endl;
			exit(-1);

		}
	}

	if(op.infile == NULL)
	{
		std::cerr << "Command line error: Input graph file is required. Use the -i switch." << std::endl;
	}

	return op;
}

void choose_device(int &max_threads_per_block, int &number_of_SMs, program_options op)
{
	int count;
	checkCudaErrors(cudaGetDeviceCount(&count));
	cudaDeviceProp prop;

	if(op.device == -1)
	{
		int maxcc=0, bestdev=0;
		for(int i=0; i<count; i++)
		{
			checkCudaErrors(cudaGetDeviceProperties(&prop,i));
			if((prop.major + 0.1*prop.minor) > maxcc)
			{
				maxcc = prop.major + 0.1*prop.minor;
				bestdev = i;
			}	
		}

		checkCudaErrors(cudaSetDevice(bestdev));
		checkCudaErrors(cudaGetDeviceProperties(&prop,bestdev));
	}
	else if((op.device < -1) || (op.device >= count))
	{
		std::cerr << "Invalid device argument. Valid devices on this machine range from 0 through " << count-1 << "." << std::endl;
		exit(-1);
	}
	else
	{
		checkCudaErrors(cudaSetDevice(op.device));
		checkCudaErrors(cudaGetDeviceProperties(&prop,op.device));
	}

	std::cout << "Chosen Device: " << prop.name << std::endl;
	std::cout << "Compute Capability: " << prop.major << "." << prop.minor << std::endl;
	std::cout << "Number of Streaming Multiprocessors: " << prop.multiProcessorCount << std::endl;
	std::cout << "Size of Global Memory: " << prop.totalGlobalMem/(float)(1024*1024*1024) << " GB" << std::endl << std::endl;

	max_threads_per_block = prop.maxThreadsPerBlock;
	number_of_SMs = prop.multiProcessorCount;
}

void verify(graph g, const std::vector<float> bc_cpu, const std::vector<float> bc_gpu)
{
	double error = 0;
	double max_error = 0;
	for(int i=0; i<g.n; i++)
	{
		double current_error = abs(bc_cpu[i] - bc_gpu[i]);
		error += current_error*current_error;
		if(current_error > max_error)
		{
			max_error = current_error;
		}
	}
	error = error/(float)g.n;
	error = sqrt(error);
	std::cout << "RMS Error: " << error << std::endl;
	std::cout << "Maximum error: " << max_error << std::endl;
}

bool reduce_1_degree_vertices(graph *in_g, graph *out_g) {
    out_g->total_comp = find_components_size(in_g);

    if (out_g->which_components == NULL) {
        out_g->R = new int[in_g->n + 1];
        out_g->F = new int[in_g->m * 2];
        out_g->C = new int[in_g->m * 2];
        out_g->weight = new int[in_g->n];
        std::fill_n(out_g->weight, in_g->n, 1);
        out_g->bc = new int[in_g->n];
        std::memset(out_g->bc, 0, in_g->n * sizeof(int));
        out_g->components_sizes = in_g->components_sizes;
        out_g->which_components = in_g->which_components;
        out_g->n = in_g->n;
        out_g->m = in_g->m;
    }

    int *R = new int[in_g->n + 1];
    int *F = new int[in_g->m * 2];
    int *C = new int[in_g->m * 2];

    std::memcpy(R, in_g->R, sizeof(int) * (in_g->n + 1));
    std::memcpy(F, in_g->F, sizeof(int) * (in_g->m * 2));
    std::memcpy(C, in_g->C, sizeof(int) * (in_g->m * 2));

    std::set<std::pair<int, int> > deleted;

    bool finish = true;
#ifdef DEBUG
    std::cout << "\tCSR INDEX ARRAY:\n\t\t";
    for (int i = 0; i < in_g->n; i++) {
        std::cout << R[i] << '\t';
    }
    std::cout << std::endl;
#endif

    for (int i = 0; i < in_g->n; i++) {
        if (R[i + 1] - R[i] == 1) {
            int v = C[R[i]];
            if (deleted.find(std::make_pair(i, v)) != deleted.end() ||
                deleted.find(std::make_pair(v, i)) != deleted.end())
                continue;
            finish = false;

            out_g->bc[i] += (out_g->weight[i] - 1) *
                            (out_g->components_sizes[out_g->which_components[i]] - out_g->weight[i]);
            out_g->bc[v] += (out_g->components_sizes[out_g->which_components[i]] - 1 - out_g->weight[i]) *
                            (out_g->weight[i]);
            out_g->weight[v] += out_g->weight[i];
//            out_g->bc[v] += 2 * (out_g->components_sizes[out_g->which_components[v]] -
//                                out_g->weight[v] - 1);
            out_g->which_components[i] = out_g->total_comp++;
            out_g->m--;
            //un-directed edge
            deleted.insert(std::make_pair(i, v));
            deleted.insert(std::make_pair(v, i));
        }
    }

    int r_index = 0;
    //int m = 0;
    for (int i = 0; i < in_g->n; i++) {
        out_g->R[i] = r_index;
        for (int j = R[i]; j < R[i + 1]; j++) {
            if (deleted.find(std::make_pair(i, C[j])) == deleted.end() &&
                deleted.find(std::make_pair(C[j], i)) == deleted.end()) {
                out_g->C[r_index] = C[j];
                out_g->F[r_index++] = i;
            }
        }
    }
    //std::cout << r_index << std::endl;
    out_g->R[in_g->n] = r_index;


    delete[] R;
    delete[] F;
    delete[] C;
    return finish;
}

int find_components_size(graph *g) {
    if (g->which_components != NULL)
        return g->total_comp;

    g->which_components = new int[g->n];

    std::vector<int> components_sizes(g->n, 0);

    std::vector<bool> vis(g->n, false);


    int total_components = 0;

    for (int i = 0; i < g->n; i++) {
        if (!vis[i]) {
            std::queue<int> Q;
            Q.push(i);
            vis[i] = true;
            components_sizes[total_components] = 1;
            g->which_components[i] = total_components;
            while (!Q.empty()) {
                int v = Q.front();
                Q.pop();
                for (int j = g->R[v]; j < g->R[v + 1]; j++) {
                    int u = g->C[j];
                    if (!vis[u]) {
                        vis[u] = true;
                        Q.push(u);
                        components_sizes[total_components]++;
                        g->which_components[u] = total_components;
                    }
                }
            }
            total_components++;
        }

    }
    g->components_sizes = new int[total_components];
    for (int i = 0; i < total_components; i++) {
        g->components_sizes[i] = components_sizes[i];
    }

    std::cout << "\tTotal components: " << total_components << "\n";
    return total_components;
}

