#include <iostream>
#include <iomanip>
#include <cstdlib>

#include "parse.h"
#include "sequential.h"
#include "util.cuh"
#include "kernels.cuh"

int main(int argc, char *argv[])
{
	program_options op = parse_arguments(argc,argv);
	int max_threads_per_block, number_of_SMs;
	choose_device(max_threads_per_block,number_of_SMs,op);
	
	graph g = parse(op.infile);
	graph g_out;
	int left_vertices = 0;
	if(op.one_deg_reduce){
		bool finish = reduce_1_degree_vertices(&g, &g_out);
		while (!finish) {
			finish = reduce_1_degree_vertices(&g_out, &g_out);
		}
		for (int i = 0; i < g.n; i++) {
			if (g_out.R[i + 1] - g_out.R[i] > 0) {
				left_vertices++;
			}
		}
		std::cout << "\tDeleted " << g.n - left_vertices << " vertices\n";
		std::cout << "\t1 degree vertices percent: " << (g.n - left_vertices) * 100 / (float) g.n << "%\n";
	}

	std::cout << "Number of nodes: " << g.n << std::endl;
	std::cout << "Number of edges: " << g.m << std::endl;

	//If we're approximating, choose source vertices at random
	std::set<int> source_vertices;
	if(op.approx)
	{
		op.k = g.n * op.ratio;
		if(op.k > g.n || op.k < 1)
		{
			op.k = g.n;
		}
		srand(0x4D5A);
		while(source_vertices.size() < op.k)
		{
			int temp_source = rand() % g.n;
			source_vertices.insert(temp_source);
		}
		std::cout << "vertices number: " << op.k << std::endl;
	}

	cudaEvent_t start,end;
	float CPU_time;
	std::vector<float> bc;
	if(op.verify) //Only run CPU code if verifying
	{
		start_clock(start,end);
		bc = bc_cpu(g,source_vertices);
		CPU_time = end_clock(start,end);
	}

	float GPU_time;
	std::vector<float> bc_g;
	start_clock(start,end);
	if(op.one_deg_reduce){
		bc_g = bc_gpu(g_out, max_threads_per_block, number_of_SMs, op, source_vertices, op.one_deg_reduce, g_out.weight);
	}else {
		bc_g = bc_gpu(g, max_threads_per_block, number_of_SMs, op, source_vertices, op.one_deg_reduce, g.weight);
	}
	GPU_time = end_clock(start,end);

	if(op.verify)
	{
		verify(g,bc,bc_g);
	}
	if(op.printBCscores)
	{
		g.print_BC_scores(bc_g,op.scorefile);
	}

	std::cout << std::setprecision(9);
	if(op.verify)
	{
		std::cout << "Time for CPU Algorithm: " << CPU_time << " s" << std::endl;
	}
	std::cout << "Time for GPU Algorithm: " << GPU_time << " s" << std::endl;
	
	delete[] g.R;
	delete[] g.C;
	delete[] g.F;

	return 0;
}
